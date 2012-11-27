;;;; cl-cia.lisp

(in-package #:cl-cia)

(defun read-file-to-list (file)
  (with-open-file (stream file)
    (loop for line = (read-line stream nil)
       while line collect line)))

(defun datify (datestr)
  "Attempt to convert a string to a local-time:timestamp object, using local-time:now if unable"
  ; and it always seems unable.
  (if datestr
      (handler-case
	  (local-time:parse-timestring datestr)
	(local-time::invalid-timestring () (local-time:now)))
      (local-time:now)))

(defun isarg (line)
  (when line (cl-ppcre:scan "^[A-Z][^:]*:" line)))

(defun trimmulti (lines offset)
  ""
  (if (<= (length (car lines)) offset)
      (cdr lines)
      (cons (string-trim " " (subseq (car lines) offset)) (cdr lines))))

(defun fieldinate (lines)
  "Given a set of lines following the email field format, build an association list of fields"
  (when lines
    (multiple-value-bind (start end) (isarg (car lines))
      (unless start (return-from fieldinate '()))
      (let ((nextargline (position-if #'isarg (cdr lines))))
	(let ((argname (subseq (car lines) start (- end 1))))
	  (cons
	   (cons argname
		 (if (or (not nextargline) (>= nextargline 1))
		     (trimmulti (subseq lines 0 (when nextargline (+ nextargline 1))) end)
		     (list (string-trim " " (subseq (car lines) end)))))
	   (fieldinate (if nextargline
			   (nthcdr (+ nextargline 1) lines)
			   (cdr lines)))))))))

(defun split-mail-to-head-and-body (file)
  (alexandria:when-let ((lines (read-file-to-list file)))
    (alexandria:when-let ((p (position-if (lambda (x) (string= "" x)) lines)))
      (cons (subseq lines 0 p) (subseq lines (+ p 1))))))

(defun flob (mailfile)
  (let ((l (split-mail-to-head-and-body mailfile)))
    (values (fieldinate (car l)) (fieldinate (cdr l)))))

(defun mail-element (name set)
  (let ((l (remove "" (mapcar (lambda (x) (string-trim " " x)) (cdr (assoc name set :test #'string=))) :test #'string=)))
    (if (cdr l) l (car l))))
(defun load-commit-from-mail-message (mailfile)
  (multiple-value-bind (header body)
      (flob mailfile)
    (let ((list-id (mail-element "List-Id" header))
	  ;; favor the body Date node, but fall back to header if needed
	  (date (datify (or (mail-element "Date" body) (mail-element "Date" header))))
	  (revision (or (mail-element "Revision" body) (mail-element "New Revision" body)))
	  (author (mail-element "Author" body))
	  ;; the actual commit log message
	  (log (or (mail-element "Log" body) (mail-element "Log Message" body)))
	  (files (or (mail-element "Modified Paths" body) (alexandria:flatten
							   (list
							    (mail-element "Modified" body)
							    (mail-element "Added" body)
							    (mail-element "Deleted" body)))))
	  (project '())
	  (url (mail-element "URL" body)))
      (when (and list-id date revision author log)
	;; SVN::Notify likes to shove "-----" lines in, so try to eat those
	(when (and (listp log) (cl-ppcre:scan "^-*$" (car log)) (pop log)))
	(when (and (listp files) (cl-ppcre:scan "^-*$" (car files))) (pop files))
	(setf project (find-project-by-list-id
		       (let ((list-id (mail-element "List-Id" header)))
			 (if (listp list-id)
			     (format nil "~{~a~}" list-id)
			     list-id))))
	(when (listp revision)
	  (unless url
	    (when (or (string-equal "http://" (subseq (cadr revision) 0 7)) (string-equal "https://" (subseq (cadr revision) 0 8)))
	      (setf url (cadr revision))))
	  (setf revision (car revision)))
	(when (and project revision author)
	  (values
	   (make-instance 'commit :files files :revision revision :date date :user author :url url :message log)
	   project))))))

(defun process-mail-dir (&key (maildir +db-unprocessed-mail-dir+) (hooks '()))
  "Parse all messages in a mail dir, adding parsed commit messages to the list and applying the hooks"
  (bordeaux-threads:with-lock-held (*biglock*)
    (dolist (file (cl-fad:list-directory maildir))
      (multiple-value-bind (message project) (load-commit-from-mail-message file)
	(when (add-message project message)
	  (let ((res (if hooks (mapcar (lambda (x) (funcall x message)) hooks) '(t))))
	    (unless (find nil res)
	      (rename-file file (merge-pathnames +db-processed-mail-dir+ (file-namestring file))))))))))

(defun process-xml-mail-dir (&key (maildir +db-unprocessed-xmlmail-dir+) (hooks '()))
  "Parse all messages in a mail dir, adding parsed commit messages to the list and applying the hooks"
  (bordeaux-threads:with-lock-held (*biglock*)
    (dolist (file (cl-fad:list-directory maildir))
      (let* ((l (split-mail-to-head-and-body file))
	     (body (cdr l)))
	(dolist (xml (parsexml (format nil "~{~a~}" body)))
	  (let ((project (find-project (car xml)))
		(message (caddr xml)))
	    (when (and (string-equal (car xml) "BRL-CAD")
		       (string-equal (cadr xml) "http://brlcad.org"))
	      (setf project (find-project "brl-cad wiki")))
	    (when (add-message project message)
	      (let ((res (if hooks (mapcar (lambda (x) (funcall x message)) hooks) '(t))))
		(unless (find nil res)
		  (rename-file file (merge-pathnames +db-processed-xmlmail-dir+ (file-namestring file))))))))))))

(defun pump () (process-mail-dir) (process-xml-mail-dir) (save-state))
(defvar *pump* '())
(defvar *pump-running* '())
(defun start-pump ()
  (unless (and *pump* (bordeaux-threads:threadp *pump*) (bordeaux-threads:thread-alive-p *pump*))
    (setf *pump-running* t)
    (setf *pump* (bordeaux-threads:make-thread
		  (lambda () (loop while *pump-running* do (progn (pump) (sleep 5))))
		  :name "cl-cia pumper"))))
(defun stop-pump ()
  (when (and *pump* *pump-running*)
    (setf *pump-running* '())
    (bordeaux-threads:join-thread *pump*)
    (setf *pump* '())))

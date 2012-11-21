;;;; cl-cia.lisp

(in-package #:cl-cia)

(defparameter +rcfile+ (merge-pathnames ".cia.lisp" (user-homedir-pathname)))
(when (probe-file +rcfile+) (load +rcfile+))

(defparameter +proplist+ '())
(defmacro prop (name form)
  `(progn
     (unless (boundp ',name) (defparameter ,name ,form))
     (push ',name +proplist+)))

(defun write-propfile (&optional (propfile +rcfile+))
  (labels ((prel (el)
		   (typecase el
		     (string (format nil "\"~a\"" el))
		     (list (format nil "(list ~{~a~^ ~})" (mapcar #'prel el)))
		     (pathname (format nil "#P\"~a\"" el))
		     (t el))))
    (with-open-file (out propfile :direction :output)
      (dolist (p +proplist+)
	(format out "(defparameter ~(~a~) ~a)~%" p
		(prel (symbol-value p)))))))

(prop +db-dir+ (merge-pathnames "db/cia/" (user-homedir-pathname)))
(prop +db-state+ (merge-pathnames "cia.state" +db-dir+))

; mail form assumes the procmail matching rule puts it in $HOME/db/cia/mail/
; with the trailing slash inferring mailbox dir instead of mbox file.

(prop +db-mail-dir+ (merge-pathnames "mail/" +db-dir+))
(prop +db-unprocessed-mail-dir+ (merge-pathnames "new/" +db-mail-dir+))
(prop +db-processed-mail-dir+ (merge-pathnames "cur/" +db-mail-dir+))

(prop +bot-nick+ "Notify")
(prop +bot-nickserv-passwd+ '())
(prop +bot-server+ "irc.freenode.net")
(prop +bot-realname+ "Commit Notification Bot - http://elfga.com/cia")
(prop +bot-ident+ "notify")
(prop +bot-channels+ '("#notify" "##notify"))

(defvar *biglock* (bordeaux-threads:make-lock "cl-cia"))

(defun load-state (&optional (file +db-state+))
  (if (probe-file file)
      (cl-store:restore file)
      (make-instance 'state :projects (list (make-instance 'project :name "BRL-CAD" :hooks (list #'report-commit))))))
(defun save-state (&optional (place *state*) (file +db-state+))
  (bordeaux-threads:with-lock-held (*biglock*)
    (when (dirty place)
      (setf (dirty place) '())
      (cl-store:store place file))))

(defclass project ()
  ((name :accessor name :initarg :name)
   (created :accessor created :initform (local-time:now))
   (channels :accessor channels :initarg :channels :initform '())
   (commits :accessor commits :initform '() :initarg :commits)
   (hooks :accessor hooks :initform '() :initarg :hooks)))
(defmethod print-object ((p project) stream)
  (format stream "<Project ~a ~a (~d commits)>" (name p) (channels p) (length (commits p))))
(defclass state ()
  ((projects :accessor projects :initarg :projects  :initform '())
   (notices :accessor notices :initarg :notices :initform '())
   (todo :accessor todo :initarg :todo :initform '())
   (dirty :accessor dirty :initarg :dirty :initform '())))
(defvar *state* '())
(defun add-project (project)
  (push project (projects *state*)))
(defmethod find-project ((name t) &optional (state *state*))
  (find-if (lambda (x)
	     (or
	      (string-equal (name x) name)
	      (find name (channels x) :test #'string-equal)))
	   (projects state)))
(defun all-channels (&optional (state *state*))
  (remove-duplicates (alexandria:flatten (cons '("#notify" "##notify") (mapcar #'channels (projects state)))) :test #'string-equal))
(defclass commit ()
  ((timestamp :accessor timestamp :initform (local-time:now))
   (date :accessor date :initarg :date :initform (local-time:now))
   (user :accessor user :initarg :user)
   (revision :accessor revision :initarg :revision)
   (files :accessor files :initarg :files :initform '())
   (message :accessor message :initarg :message :initform '())))

(defmethod print-object ((c commit) stream)
  (format stream "#<Commit: ~a@~a: ~a (at ~a)>" (user c) (revision c) (message c) (date c)))
(defmethod equals ((c1 commit) (c2 commit))
  (and (string-equal (user c1) (user c2)) (string-equal (revision c1) (revision c2))))

(defmethod find-commit ((p project) rev)
  (find-if (lambda (x) (string-equal (revision x) rev)) (commits p)))

(defun commit-has-file (commit filename)
  (when (find filename (files commit) :test #'string=)
    t))

(defun resort-commits (project)
  (bordeaux-threads:with-lock-held (*biglock*)
    (setf (commits project) (sort (commits project) (lambda (x y) (> (revision x) (revision y))))))
  t)

(defun remove-commit (project commit &key (test #'equals))
  (bordeaux-threads:with-recursive-lock-held (*biglock*)
    (setf (commits project) (remove commit (commits project) :test test))))

(defvar *message-hooks* '())
(defun message-seen (project message)
  (find message (commits project) :test #'equals))
(defun add-message (project message)
  (unless (message-seen project message)
    (dolist (hook (hooks project)) (funcall hook project message))
    (setf (dirty *state*) t)
    (push message (commits project))))

(defun in-the-last (commits &optional start end)
  (unless start (setf start (local-time:timestamp- (local-time:now) 24 :hour)))
  (unless end (setf end (local-time:now)))
  (remove-if (lambda (x)
               (or
                (local-time:timestamp< (cl-cia::date x) start)
                (local-time:timestamp> (cl-cia::date x) end)))
             commits))

(defun count-commits-by-user-since (commits &optional start end)
  (let ((last24hr (in-the-last commits start end))
        (bucket '()))
    (dolist (c last24hr)
      (let ((suck (assoc (user c) bucket :test #'string-equal)))
        (if suck
            (incf (cadr suck))
            (push (list (user c) 1) bucket))))
    (sort bucket (lambda (x y) (> (cadr x) (cadr y))))))

(defun start ()
  (setf *state* (load-state))
  (setf *message-hooks* (list #'report-commit))
  (bot)
  (sleep 5)
  (start-pump))
(defun stop ()
  (stop-bot)
  (stop-pump)
  (save-state))

;;;; cl-cia.lisp

(in-package #:cl-cia)

(defparameter +rcfile+ (merge-pathnames ".cia.lisp" (user-homedir-pathname)))
(when (probe-file +rcfile+) (load +rcfile+))

(defmacro prop (name form) `(unless (boundp ',name) (defparameter ,name ,form)))

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
(prop +bot-realname+ "BRL-CAD Commit Notification Bot")
(prop +bot-ident+ "brlbot")
(prop +bot-channels+ '("#brlcad"))

(defvar *biglock* (bordeaux-threads:make-lock "cl-cia"))

(defun load-state (&optional (place *state*) (file +db-state+))
  (unless place
    (if (probe-file file)
	(setf place (cl-store:restore file))
	(setf place (make-instance 'state :projects (list (make-instance 'project :name "BRL-CAD" :hooks (list #'report-commit))))))))  
(defun save-state (&optional (place *state*) (file +db-state+))
  (cl-store:store place file))

(defclass project ()
  ((name :accessor name :initarg :name)
   (created :accessor created :initform (local-time:now))
   (channel :accessor channel :initarg :channel)
   (commits :accessor commits :initform '() :initarg :commits)
   (hooks :accessor hooks :initform '() :initarg :hooks)))
(defmethod print-object ((p project) stream)
  (format stream "<Project ~a ~a (~d commits)>" (name p) (channel p) (length (commits p))))
(defclass state ()
  ((projects :accessor projects :initarg :projects  :initform '())))
(defvar *state* '())
(defun add-project (project)
  (push project (projects *state*)))
(defmethod find-project ((name t) &optional (state *state*))
  (find-if (lambda (x) (string-equal (name x) name)) (projects state)))
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
  (and (string-equal (user c1) (user c2)) (= (revision c1) (revision c2))))

(defmethod find-commit ((p project) (rev integer))
  (find-if (lambda (x) (= (revision x) rev)) (commits p)))

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
    (push message (commits project))
    (save-state)))

(defun start ()
  (load-state)
  (setf *message-hooks* (list #'report-commit))
  (bot)
  (sleep 5)
  (start-pump))
(defun stop ()
  (stop-bot)
  (stop-pump)
  (save-state))

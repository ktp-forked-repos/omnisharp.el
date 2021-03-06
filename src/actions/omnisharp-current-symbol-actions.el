;; -*- lexical-binding: t -*-
(defcustom omnisharp-find-usages-exclude-definition t
  "Set to t if you want to exclude the member definition
  from the usages"
  :group 'omnisharp
  :type '(choice (const :tag "Yes" t)
                 (const :tag "No" nil)))

(defvar omnisharp-project-dir-occur nil
  "Holds the current project directory for `ivy-occur'")

(defun omnisharp-current-type-information (&optional add-to-kill-ring)
  "Display information of the current type under point. With prefix
argument, add the displayed result to the kill ring. This can be used
to insert the result in code, for example."
  (interactive "P")
  (omnisharp-current-type-information-worker 'Type))

(defun omnisharp-current-type-documentation (&optional add-to-kill-ring)
  "Display documentation of the current type under point. With prefix
argument, add the displayed result to the kill ring. This can be used
to insert the result in code, for example."
  (interactive "P")
  (omnisharp-current-type-information-worker 'Documentation))

(defun omnisharp-current-type-information-worker (type-property-name
                                                  &optional add-to-kill-ring)
  "Get type info from the API and display a part of the response as a
message. TYPE-PROPERTY-NAME is a symbol in the type lookup response
from the server side, i.e. 'Type or 'Documentation that will be
displayed to the user."
  (omnisharp--send-command-to-server
   "typelookup"
   (omnisharp--get-request-object)
   (lambda (response)
     (let ((stuff-to-display (cdr (assoc type-property-name
                                         response))))
       (message stuff-to-display)
       (when add-to-kill-ring
         (kill-new stuff-to-display))))))

(defun omnisharp-current-type-information-to-kill-ring ()
  "Shows the information of the current type and adds it to the kill
ring."
  (interactive)
  (omnisharp-current-type-information t))

(ivy-set-occur 'omnisharp-find-usages 'omnisharp-find-usages-occur)

(defun omnisharp-find-usages ()
  "Find usages for the symbol under point"
  (interactive)
  (setq omnisharp-project-dir-occur (projectile-project-root))
  (let ((candidates (omnisharp--get-usages-from-server)))
    (cond ((= (length candidates) 1)
           (omnisharp--avy-go-to-file-and-column (car candidates)))
          ((> (length candidates) 1)
           (ivy-read "usages:" candidates
                     :action 'omnisharp--avy-go-to-file-and-column
                     :caller 'omnisharp-find-usages))
          (t (message "No usages found")))))

(defun omnisharp-find-usages-occur ()
  "Generates a custom occur buffer to work with `wgrep'"
  (unless (eq major-mode 'ivy-occur-grep-mode)
    (ivy-occur-grep-mode))
  (setq default-directory omnisharp-project-dir-occur)
  ;; Need precise number of header lines for `wgrep' to work.
  (let ((cands ivy--all-candidates))
    (insert (format "-*- mode:grep; default-directory: %S -*-\n\n\n"
                    omnisharp-project-dir-occur))
    (insert (format "%d candidates:\n" (length cands)))
    (ivy--occur-insert-lines
     (mapcar
      (lambda (cand) (concat "./" cand))
      cands))))

(defun omnisharp--get-usages-from-server ()
  "Returns a list of all usages of symbol at point"
  (let (cands)
    (omnisharp--send-command-to-server-sync
     "findusages"
     (->> (omnisharp--get-request-object)
          (cons `(ExcludeDefinition . ,(omnisharp--t-or-json-false
                                        omnisharp-find-usages-exclude-definition))))
     (-lambda ((&alist 'QuickFixes quickfixes))
       (setq cands (omnisharp--find-usages-format quickfixes))))
    cands))

(make-face 'omnisharp-file-face)
(make-face 'omnisharp-lineno-face)
(defun omnisharp--find-usages-format (quickfixes)
  (if (equal 0 (length quickfixes))
      (message "No usages found.")
    (-map (-lambda ((x &as &alist
                       'Text text
                       'FileName file
                       'Line line))
            (propertize (format "%s:%s:%s"
				(propertize (file-relative-name file omnisharp-project-dir-occur) 'face 'omnisharp-file-face)
				(propertize (number-to-string line) 'face 'omnisharp-lineno-face) text) 'property x))
	  quickfixes)))

(defun omnisharp-find-implementations-with-ido (&optional other-window)
  (interactive "P")
  (omnisharp--send-command-to-server-sync
   "findimplementations"
   (omnisharp--get-request-object)
   (lambda (quickfix-response)
     (omnisharp--show-or-navigate-to-quickfixes-with-ido quickfix-response
                                                         other-window))))

(defun omnisharp--show-or-navigate-to-quickfixes-with-ido (quickfix-response
                                                           &optional other-window)
  (-let (((&alist 'QuickFixes quickfixes) quickfix-response))
    (cond ((equal 0 (length quickfixes))
           (message "No implementations found."))
          ((equal 1 (length quickfixes))
           (omnisharp-go-to-file-line-and-column (-first-item (omnisharp--vector-to-list quickfixes))
                                                 other-window))
          (t
           (omnisharp--choose-and-go-to-quickfix-ido quickfixes other-window)))))

(defun omnisharp-find-implementations ()
  "Show a buffer containing all implementations of the interface under
point, or classes derived from the class under point. Allow the user
to select one (or more) to jump to."
  (interactive)
  (message "Finding implementations...")
  (omnisharp-find-implementations-worker
   (omnisharp--get-request-object)
   (lambda (quickfixes)
     (cond ((equal 0 (length quickfixes))
            (message "No implementations found."))

           ;; Go directly to the implementation if there only is one
           ((equal 1 (length quickfixes))
            (omnisharp-go-to-file-line-and-column (car quickfixes)))

           (t
            (omnisharp--write-quickfixes-to-compilation-buffer
             quickfixes
             omnisharp--find-implementations-buffer-name
             omnisharp-find-implementations-header))))))

(defun omnisharp-find-implementations-worker (request callback)
  "Gets a list of QuickFix lisp objects from a findimplementations api call
asynchronously. On completions, CALLBACK is run with the quickfixes as its only argument."
  (omnisharp--send-command-to-server
   "findimplementations"
   request
   (-lambda ((&alist 'QuickFixes quickfixes))
            (apply callback (list (omnisharp--vector-to-list quickfixes))))))

(defun omnisharp-rename ()
  "Rename the current symbol to a new name. Lets the user choose what
name to rename to, defaulting to the current name of the symbol."
  (interactive)
  (let* ((current-word (thing-at-point 'symbol))
         (rename-to (read-string "Rename to: " current-word))
         (rename-request
          (->> (omnisharp--get-request-object)
            (cons `(RenameTo . ,rename-to))
            (cons `(WantsTextChanges . true))))
         (location-before-rename
          (omnisharp--get-request-object-for-emacs-side-use)))
    (omnisharp--send-command-to-server-sync
     "rename"
     rename-request
     (lambda (rename-response) (omnisharp--rename-worker
                                rename-response
                                location-before-rename)))))

(defun omnisharp--rename-worker (rename-response
                                 location-before-rename)
  (-if-let (error-message (cdr (assoc 'ErrorMessage rename-response)))
      (message error-message)
    (-let (((&alist 'Changes modified-file-responses) rename-response))
      ;; The server will possibly update some files that are currently open.
      ;; Save all buffers to avoid conflicts / losing changes
      (save-some-buffers t)

      (-map #'omnisharp--apply-text-changes modified-file-responses)

      ;; Keep point in the buffer that initialized the rename so that
      ;; the user does not feel disoriented
      (omnisharp-go-to-file-line-and-column location-before-rename)

      (message "Rename complete in files: \n%s"
               (-interpose "\n" (--map (cdr (assoc 'FileName it))
                                       modified-file-responses))))))

(defun omnisharp--apply-text-changes (modified-file-response)
  (-let (((&alist 'Changes changes
                  'FileName file-name) modified-file-response))
    (omnisharp--update-files-with-text-changes
     file-name
     (omnisharp--vector-to-list changes))))

(defun omnisharp-rename-interactively ()
  "Rename the current symbol to a new name. Lets the user choose what
name to rename to, defaulting to the current name of the symbol. Any
renames require interactive confirmation from the user."
  (interactive)
  (let* ((current-word (thing-at-point 'symbol))
         (rename-to (read-string "Rename to: " current-word))
         (delimited
          (y-or-n-p "Only rename full words?"))
         (all-solution-files
          (omnisharp--get-solution-files-list-of-strings))
         (location-before-rename
          (omnisharp--get-request-object-for-emacs-side-use)))

    (setq omnisharp--current-solution-files all-solution-files)
    (tags-query-replace current-word
                        rename-to
                        delimited
                        ;; This is expected to be a form that will be
                        ;; evaluated to get the list of all files to
                        ;; process.
                        'omnisharp--current-solution-files)
    ;; Keep point in the buffer that initialized the rename so that
    ;; the user deos not feel disoriented
    (omnisharp-go-to-file-line-and-column location-before-rename)))

(provide 'omnisharp-current-symbol-actions)

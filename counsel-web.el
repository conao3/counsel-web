;;; counsel-web.el --- Search the Web using Ivy -*- lexical-binding: t -*-

;; Author: Matthew Sojourner Newton
;; Maintainer: Matthew Sojourner Newton
;; Version: "0.1"
;; Package-Requires: ((emacs "25.1") (swiper "0.12.0") (request "0.3.0"))
;; Homepage: N/A
;; Keywords: search web


;; This file is not part of GNU Emacs

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; For a full copy of the GNU General Public License
;; see <http://www.gnu.org/licenses/>.


;;; Commentary:

;; Asynchronously search the Web using Ivy.

;;; TODO:
;;  `counsel-web-at-point'
;; - Option to not update search dynamically
;; - See https://github.com/Malabarba/emacs-google-this
;; - See https://github.com/hrs/engine-mode

;;; Code:

(require 'dom)
(require 'request)
(require 'counsel)


;;;; Variables

(defcustom counsel-web-suggest-function #'counsel-web-suggest--duckduckgo
  "The function to call to retrieve suggestions."
  :group 'counsel-web
  :type 'symbol)

(defcustom counsel-web-suggest-action #'counsel-web-search
  "The function to call when a suggestion candidate is selected."
  :group 'counsel-web
  :type 'symbol)

(defcustom counsel-web-search-function #'counsel-web-search--duckduckgo
  "The function to call to retrieve search results."
  :group 'counsel-web
  :type 'symbol)

(defcustom counsel-web-search-action #'eww
  "The function to call when a search candidate is selected."
  :group 'counsel-web
  :type 'symbol)

(defcustom counsel-web-search-alternate-action #'browse-url-default-browser
  "The function to call when a search candidate is selected (alternate)."
  :group 'counsel-web
  :type 'symbol)

(defcustom counsel-web-search-dynamic-update nil
  "If non-nil, update search with each change in the minibuffer."
  :group 'counsel-web
  :type 'boolean)

(defvar counsel-web-suggest-history nil
  "History for `counsel-web-suggest'.")

(defvar counsel-web-search-history nil
  "History for `counsel-web-search'.")

(defvar counsel-web-search--browse-first-result nil
  "If non-nil, immediately select the first candidate.")

;;;; Functions

(defun counsel-web--format-candidate (text url)
  "Format TEXT and URL as an `ivy-read' candidate."
  (let ((url (url-unhex-string url)))
    (propertize (concat text "\n" (propertize url 'face 'shadow)) 'shr-url url)))

(cl-defun counsel-web--handle-error (&rest args &key error-thrown &allow-other-keys)
  (message "Web search error: %S" error-thrown))

(cl-defun counsel-web--async-sentinel (&key data &allow-other-keys)
  "Sentinel function for an asynchronous counsel web request.

Adapted from `counsel--async-sentinel'."
  (when data
    (ivy--set-candidates (ivy--sort-maybe data))
    (when counsel--async-start
      (setq counsel--async-duration
            (time-to-seconds (time-since counsel--async-start))))
    (let ((re (ivy-re-to-str (funcall ivy--regex-function ivy-text))))
      (if ivy--old-cands
          (if (eq (ivy-alist-setting ivy-index-functions-alist)
                  'ivy-recompute-index-zero)
              (ivy-set-index 0)
            (ivy--recompute-index ivy-text re ivy--all-candidates))
        (unless (ivy-set-index
                 (ivy--preselect-index
                  (ivy-state-preselect ivy-last)
                  ivy--all-candidates))
          (ivy--recompute-index ivy-text re ivy--all-candidates))))
    (setq ivy--old-cands ivy--all-candidates)
    (if ivy--all-candidates
        (ivy--exhibit)
      (ivy--insert-minibuffer ""))
    (when counsel-web-search--browse-first-result (ivy-done))))

(defun counsel-web--request (url parser &optional placeholder)
  "Search using the given URL and PARSER.

PLACEHOLDER is returned for immediate display by `ivy-read'. The
actual list of candidates is later updated by the \:success
function."
  (if counsel-web-search-dynamic-update
      (progn
        (request
         url
         :headers '(("User-Agent" . "Emacs"))
         :parser parser
         :error #'counsel-web--handle-error
         :success #'counsel-web--async-sentinel)
        placeholder)
    (let (candidates)
      (request
       url
       :sync t
       :headers '(("User-Agent" . "Emacs"))
       :parser parser
       :error #'counsel-web--handle-error
       :success (cl-function (lambda (&key data &allow-other-keys)
                               (setq candidates data))))
      candidates)))

(defun counsel-web--duckduckgo-search-url (string)
  "Make search URL from STRING."
  (concat "https://duckduckgo.com/html/?q=" (url-hexify-string string)))

(defun counsel-web-suggest--duckduckgo (string)
  "Retrieve search suggestions from DuckDuckGo for STRING."
  (counsel-web--request
   (format "https://ac.duckduckgo.com/ac/?q=%s&amp;type=list"
           (url-hexify-string string))
   (lambda ()
     (mapcar
      (lambda (e)
        (let ((s (cdar e)))
          (propertize s 'shr-url (counsel-web--duckduckgo-search-url s))))
      (append (json-read) nil)))))

(defun counsel-web-search--duckduckgo (string)
  "Retrieve search results from DuckDuckGo for STRING."
  (counsel-web--request
   (concat "https://duckduckgo.com/html/?q=" (url-hexify-string string))
   (lambda ()
     (mapcar
      (lambda (a)
        (let* ((href (assoc-default 'href (dom-attributes a))))
          (counsel-web--format-candidate
           (dom-texts a)
           (substring href (string-match "http" href)))))
      (dom-by-class (libxml-parse-html-region (point-min) (point-max)) "result__a")))
   (list "" "Searching DuckDuckGo...")))

(defun counsel-web-suggest--google (string)
  "Retrieve search suggestions from Google for STRING."
  (counsel-web--request
   (concat "https://suggestqueries.google.com/complete/search?output=firefox&q="
           (url-hexify-string string))
   (lambda () (append (elt (json-read) 1) nil))))

(defun counsel-web-search--google (string)
  "Retrieve search results from Google for STRING."
  (counsel-web--request
   (concat "https://www.google.com/search?q=" (url-hexify-string string))
   (lambda ()
     (cl-loop for a in (dom-by-tag (libxml-parse-html-region (point-min) (point-max))
                                   'a)
              when (string-match "/url\\?q=\\(http[^&]+\\)"
                                 (assoc-default 'href (dom-attributes a)))
              collect
              (counsel-web--format-candidate
               (dom-texts a)
               (substring (assoc-default 'href (dom-attributes a))
                          (match-beginning 1) (match-end 1)))))
   (list "" "Searching Google...")))

(defun counsel-web-suggest--collection-function (string)
  "Retrieve search suggestions for STRING."
  (or
   (let ((ivy-text string))
     (ivy-more-chars))
   (funcall counsel-web-suggest-function string)))

(defun counsel-web-search--async-collection-function (string)
  "Retrieve search results for STRING asynchronously."
  (or (let ((ivy-text string))
        (ivy-more-chars))
      (funcall counsel-web-search-function string)))

(defun counsel-web-search--sync-collection-function
    (string collection &optional predicate)
  "Retrieve search results for STRING synchronously."
  (let ((collection (or collection (funcall counsel-web-search-function string))))
    (if (functionp predicate)
        (seq-filter predicate collection)
      collection)))

(defun counsel-web-search--browse-first-result (string)
  "Immediately browse the first result the search for STRING."
  (let ((counsel-web-search--browse-first-result t))
    (counsel-web-search string)))

(defun counsel-web-search--do-action (candidate)
  "Pass the CANDIDATE's url to `counsel-web-search-action'."
  (funcall-interactively counsel-web-search-action
                         (get-text-property 0 'shr-url candidate)))

(defun counsel-web-search--do-alternate-action (candidate)
  "Pass the CANDIDATE's url to `counsel-web-search-action'."
  (funcall-interactively counsel-web-search-alternate-action
                         (get-text-property 0 'shr-url candidate)))

(defun counsel-web-search--do-action-other-window (candidate)
  "Switch to other window and call the action on the CANDIDATE."
  (other-window 1)
  (counsel-web-search--do-action candidate))


;;;; Commands

;;;###autoload
(defun counsel-web-suggest (&optional initial-input prompt suggest-function action)
  "Perform a web search with asynchronous suggestions.

INITIAL-INPUT can be given as the initial minibuffer input.
PROMPT, if non-nil, is passed as `ivy-read' prompt argument.
SUGGEST-FUNCTION, if non-nil, is called to perform the search.
ACTION, if non-nil, is called to load the selected candidate."
  (interactive)
  (let ((counsel-web-suggest-function (or suggest-function counsel-web-suggest-function)))
    (ivy-read (or prompt "Web Search: ")
              #'counsel-web-suggest--collection-function
              :initial-input initial-input
              :dynamic-collection t
              :history 'counsel-web-suggest-history
              :action (or action counsel-web-suggest-action)
              :caller 'counsel-web-suggest)))

(ivy-add-actions
 'counsel-web-suggest
 `(("f" counsel-web-search--browse-first-result "first candidate")))

;;;###autoload
(defun counsel-web-search (&optional string prompt search-function action)
  "Perform a web search for STRING and return the results in `ivy-read'.

PROMPT, if non-nil, is passed as `ivy-read' prompt argument.
SEARCH-FUNCTION, if non-nil, is called to perform the search.
ACTION, if non-nil, is called to load the selected candidate."
  (interactive)
  (if string
      (let ((counsel-web-search-function (or search-function counsel-web-search-function))
            (counsel-web-search-action (or action counsel-web-search-action))
            (collection-function (if  counsel-web-search-dynamic-update
                                     #'counsel-web-search--async-collection-function
                                   #'counsel-web-search--sync-collection-function))
            (minibuffer-setup-hook
             (append minibuffer-setup-hook
                     (lambda () (face-remap-add-relative 'bold 'ivy-current-match)))))
        (ivy-read (or prompt "Browse: ")
                  collection-function
                  :initial-input string
                  :dynamic-collection counsel-web-search-dynamic-update
                  :require-match t
                  :history 'counsel-web-search-history
                  :action #'counsel-web-search--do-action
                  :caller 'counsel-web-search))
    (counsel-web-suggest string prompt nil #'counsel-web-search)))

(ivy-add-actions
 'counsel-web-search
 `(("j" counsel-web-search--do-action-other-window "other window")
   ("m" counsel-web-search--do-alternate-action "alternate browser")))

(provide 'counsel-web)

;;; counsel-web.el ends here
;;; marginalia.el --- Enrich existing commands with completion annotations -*- lexical-binding: t -*-

;; Author: Omar Antolín Camarena, Daniel Mendler
;; Maintainer: Omar Antolín Camarena, Daniel Mendler
;; Created: 2020
;; License: GPL-3.0-or-later
;; Version: 0.1
;; Package-Requires: ((emacs "26.1"))
;; Homepage: https://github.com/minad/marginalia

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Enrich existing commands with completion annotations

;;; Code:

(require 'subr-x)
(eval-when-compile (require 'cl-lib))

;;;; Customization

(defgroup marginalia nil
  "Enrich existing commands with completion annotations."
  :group 'convenience
  :prefix "marginalia-")

(defface marginalia-key
  '((t :inherit font-lock-keyword-face :weight normal))
  "Face used to highlight keys in `marginalia-mode'."
  :group 'marginalia)

(defface marginalia-documentation
  '((t :inherit completions-annotations :weight normal))
  "Face used to highlight documentation string in `marginalia-mode'."
  :group 'marginalia)

(defface marginalia-variable
  '((t :inherit marginalia-key))
  "Face used to highlight variable values in `marginalia-mode'."
  :group 'marginalia)

(defface marginalia-mode
  '((t :inherit marginalia-key))
  "Face used to highlight major modes in `marginalia-mode'."
  :group 'marginalia)

(defface marginalia-date
  '((t :inherit marginalia-key))
  "Face used to highlight dates in `marginalia-mode'."
  :group 'marginalia)

(defface marginalia-size
  '((t :inherit font-lock-constant-face :weight normal))
  "Face used to highlight sizes in `marginalia-mode'."
  :group 'marginalia)

(defface marginalia-file-name
  '((t :inherit marginalia-documentation))
  "Face used to highlight file names in `marginalia-mode'."
  :group 'marginalia)

(defcustom marginalia-documentation-width 80
  "Width of documentation string."
  :type 'integer
  :group 'marginalia)

(defcustom marginalia-file-name-width 80
  "Width of file name."
  :type 'integer
  :group 'marginalia)

(defcustom marginalia-separator-width 4
  "Field separator width."
  :type 'string
  :group 'marginalia)

(defcustom marginalia-variable-width 30
  "Width of variable value annotation string."
  :type 'integer
  :group 'marginalia)

(defcustom marginalia-annotators
  '(marginalia-annotators-light marginalia-annotators-heavy)
  "Choose an annotator association list for minibuffer completion.
The first entry in the list is used for annotations.
You can toggle between the annotators using `marginalia-toggle-annotators'.
Annotations are only shown if `marginalia-mode' is enabled."
  :type '(repeat (choice (const :tag "Light" marginalia-annotators-light)
                         (const :tag "Heavy" marginalia-annotators-heavy)
                         (symbol :tag "Other")))
  :group 'marginalia)

(defcustom marginalia-annotators-light
  '((command . marginalia-annotate-command-binding)
    (customize-group . marginalia-annotate-customize-group)
    (variable . marginalia-annotate-variable)
    (face . marginalia-annotate-face)
    (symbol . marginalia-annotate-symbol)
    (variable . marginalia-annotate-variable)
    (package . marginalia-annotate-package))
  "Lightweight annotator functions.
Associates completion categories with annotation functions.
Each annotation function must return a string,
which is appended to the completion candidate.
See also `marginalia-annotators-heavy'."
  :type '(alist :key-type symbol :value-type function)
  :group 'marginalia)

(defcustom marginalia-annotators-heavy
  (append
   '((file . marginalia-annotate-file)
     (buffer . marginalia-annotate-buffer)
     (command . marginalia-annotate-command-full))
   marginalia-annotators-light)
  "Heavy annotator functions.

Associates completion categories with annotation functions.
Each annotation function must return a string,
which is appended to the completion candidate.
See also `marginalia-annotators-light'."
  :type '(alist :key-type symbol :value-type function)
  :group 'marginalia)

(defcustom marginalia-classifiers
  '(marginalia-classify-by-command-name
    marginalia-classify-original-category
    marginalia-classify-by-prompt
    marginalia-classify-symbol)
  "List of functions to determine current completion category.
Each function should take no arguments and return a symbol
indicating the category, or nil to indicate it could not
determine it."
  :type 'hook
  :group 'marginalia)

(defcustom marginalia-prompt-categories
  '(("\\<group\\>" . customize-group)
    ("\\<M-x\\>" . command)
    ("\\<package\\>" . package)
    ("\\<face\\>" . face)
    ("\\<variable\\>" . variable))
  "Associates regexps to match against minibuffer prompts with categories."
  :type '(alist :key-type regexp :value-type symbol)
  :group 'marginalia)

(defcustom marginalia-command-categories nil
  "Associate commands with a completion category."
  :type '(alist :key-type symbol :value-type symbol)
  :group 'marginalia)

;;;; Pre-declarations for external packages

(defvar package--builtins)
(defvar package-alist)
(defvar package-archive-contents)
(declare-function package-desc-summary "package")
(declare-function package--from-builtin "package")

;;;; Marginalia mode

(defvar marginalia--this-command nil
  "Last command symbol saved in order to allow annotations.")

(defvar marginalia--original-category nil
  "Original category reported by completion metadata.")

(defmacro marginalia--align (&rest align)
  "Align annotations to ALIGN."
  (concat " "
          (propertize
           " "
           'display
           `(space :align-to (- right-fringe ,@align)))))

(defsubst marginalia--separator ()
  "Return separator string."
  (make-string marginalia-separator-width 32))

(defun marginalia--documentation (str)
  "Format documentation string STR."
  (concat
   (marginalia--align marginalia-documentation-width)
   (propertize (marginalia--truncate str marginalia-documentation-width)
               'face 'marginalia-documentation)))

(defun marginalia--truncate (str width)
  "Truncate string STR to WIDTH."
  (truncate-string-to-width (car (split-string str "\n")) width 0 32 "…"))

(defun marginalia-annotate-command-binding (cand)
  "Annotate command CAND with keybinding."
  ;; Taken from Emacs 28, read-extended-command--annotation
  (when-let* ((binding
               (with-current-buffer (window-buffer (minibuffer-selected-window))
                 (where-is-internal (intern cand) overriding-local-map t)))
              (desc (and (not (stringp binding)) (key-description binding))))
    (propertize (format " (%s)" desc) 'face 'marginalia-key)))

(defun marginalia-annotate-command-full (cand)
  "Annotate command CAND with the keybinding and its documentation string."
  (concat
   (marginalia-annotate-command-binding cand)
   (marginalia-annotate-symbol cand)))

(defun marginalia-annotate-symbol (cand)
  "Annotate symbol CAND with its documentation string."
  (when-let (doc (let ((sym (intern cand)))
                   (cond
                    ((fboundp sym) (ignore-errors (documentation sym)))
                    ((facep sym) (documentation-property sym 'face-documentation))
                    (t (documentation-property sym 'variable-documentation)))))
    (marginalia--documentation doc)))

(defun marginalia-annotate-variable (cand)
  "Annotate variable CAND with its documentation string."
  (let ((sym (intern cand)))
    (when-let (doc (documentation-property sym 'variable-documentation))
      (concat
       (marginalia--align marginalia-variable-width marginalia-documentation-width)
       (propertize (marginalia--truncate (format "%S" (if (boundp sym)
                                                          (symbol-value sym)
                                                        'unbound))
                                         marginalia-variable-width)
                   'face 'marginalia-variable)
       (marginalia--separator)
       (propertize (marginalia--truncate doc marginalia-documentation-width)
                   'face 'marginalia-documentation)))))

(defun marginalia-annotate-face (cand)
  "Annotate face CAND with documentation string and face example."
  (let ((sym (intern cand)))
    (when-let (doc (documentation-property sym 'face-documentation))
      (concat
       (marginalia--align marginalia-documentation-width marginalia-separator-width 26)
       (propertize "abcdefghijklmNOPQRSTUVWXYZ" 'face sym)
       (marginalia--separator)
       (propertize (marginalia--truncate doc marginalia-documentation-width)
                   'face 'marginalia-documentation)))))

(defun marginalia-annotate-package (cand)
  "Annotate package CAND with its description summary."
  (when-let* ((pkg (intern (replace-regexp-in-string "-[[:digit:]\\.-]+$" "" cand)))
              ;; taken from embark.el, originally `describe-package-1`
              (desc (or (car (alist-get pkg package-alist))
                        (if-let (built-in (assq pkg package--builtins))
                            (package--from-builtin built-in)
                          (car (alist-get pkg package-archive-contents))))))
    (marginalia--documentation (package-desc-summary desc))))

(defun marginalia-annotate-customize-group (cand)
  "Annotate customization group CAND with its documentation string."
  (when-let (doc (documentation-property (intern cand) 'group-documentation))
    (marginalia--documentation doc)))

(defun marginalia-annotate-buffer (cand)
  "Annotate buffer CAND with modification status, file name and major mode."
  (when-let (buffer (get-buffer cand))
    (concat
     (marginalia--align 2 ;; modification
                        30 ;; mode
                        marginalia-separator-width
                        marginalia-file-name-width)
     (if (buffer-modified-p buffer) "*" " ")
     (if (buffer-local-value 'buffer-read-only buffer) "%" " ")
     " "
     (propertize
      (format "%-30s" (buffer-local-value 'major-mode buffer))
      'face 'marginalia-mode)
     (marginalia--separator)
     (marginalia--truncate
      (if-let (file (buffer-file-name buffer))
          (propertize (abbreviate-file-name file)
                      'face 'marginalia-file-name)
        "")
      marginalia-file-name-width))))

;; At some point we might want to revisit how this function is implemented. Maybe we come up with a
;; more direct way to implement it. While Emacs does not use the notion of "full candidate", there
;; is a function `completion-boundaries' to compute them, and in (info "(elisp)Programmed
;; Completion") it is documented how a completion table should respond to boundaries requests.
;; See the discussion at https://github.com/minad/marginalia/commit/4ba98045dd33bcf1396a888dbbae2dc801dce7c5
(defun marginalia--full-candidate (cand)
  "Return completion candidate CAND in full.
For some completion tables, the completion candidates offered are
meant to be only a part of the full minibuffer contents. For
example, during file name completion the candidates are one path
component of a full file path.

This function returns what would be the minibuffer contents after
using `minibuffer-force-complete' on the candidate CAND."
  (or
   ;; Selectrum allows access to the full-candidate via property
   ;; TODO The generic method which follows, does not work yet with selectrum.
   ;; https://github.com/raxod502/selectrum/issues/255
   (get-text-property 0 'selectrum-candidate-full cand)

   ;; When in the minibuffer, use the minibuffer contents to expand the candidate.
   (and (minibufferp)
        (let* ((contents (minibuffer-contents))
               (pt (- (point) (minibuffer-prompt-end)))
               (bounds (completion-boundaries
                        (substring contents 0 pt)
                        minibuffer-completion-table
                        minibuffer-completion-predicate
                        (substring contents pt))))
          (concat (substring contents 0 (car bounds))
                  cand
                  (substring contents (+ pt (cdr bounds))))))

   ;; Not in a minibuffer, trust that cand already conveys all
   ;; information, since there is nothing we can do.
   cand))

(defun marginalia-annotate-file (cand)
  "Annotate file CAND with its size and modification time."
  (when-let ((attributes (file-attributes (marginalia--full-candidate cand) 'string)))
    (concat
     (marginalia--align 10 marginalia-separator-width ;; modes
                        12 marginalia-separator-width ;; user:group
                        7 marginalia-separator-width ;; size
                        12 ;; date
                        20) ;; offset
     (file-attribute-modes attributes)
     (marginalia--separator)
     (format "%12s" (format "%s:%s"
                            (file-attribute-user-id attributes)
                            (file-attribute-group-id attributes)))
     (marginalia--separator)
     (propertize (format "%7s" (file-size-human-readable (file-attribute-size attributes)))
                 'face 'marginalia-size)
     (marginalia--separator)
     (propertize (format-time-string
                  "%b %d %H:%M"
                  (file-attribute-modification-time attributes))
                 'face 'marginalia-date))))

(defun marginalia-classify-by-command-name ()
  "Lookup category for current command."
  (and marginalia--this-command
       (alist-get marginalia--this-command marginalia-command-categories)))

(defun marginalia-classify-original-category ()
  "Return original category reported by completion metadata."
  marginalia--original-category)

(defun marginalia-classify-symbol ()
  "Determine if currently completing symbols."
  (when-let (mct minibuffer-completion-table)
    (when (or (eq mct 'help--symbol-completion-table)
              (obarrayp mct)
              (and (consp mct) (symbolp (car mct))) ; assume list of symbols
              ;; imenu from an Emacs Lisp buffer produces symbols
              (and (eq marginalia--this-command 'imenu)
                   (with-current-buffer
                       (window-buffer (minibuffer-selected-window))
                     (derived-mode-p 'emacs-lisp-mode))))
      'symbol)))

(defun marginalia-classify-by-prompt ()
  "Determine category by matching regexps against the minibuffer prompt.
This runs through the `marginalia-prompt-categories' alist
looking for a regexp that matches the prompt."
  (when-let (prompt (minibuffer-prompt))
    (setq prompt
          (replace-regexp-in-string "(.*default.*)\\|\\[.*\\]" "" prompt))
    (cl-loop for (regexp . category) in marginalia-prompt-categories
             when (string-match-p regexp prompt)
             return category)))

(defun marginalia--completion-metadata-get (metadata prop)
  "Meant as :before-until advice for `completion-metadata-get'.
METADATA is the metadata.
PROP is the property which is looked up."
  (pcase prop
    ('annotation-function
     (when-let (cat (completion-metadata-get metadata 'category))
       ;; we do want the advice triggered for completion-metadata-get
       (alist-get cat (symbol-value (car marginalia-annotators)))))
    ('category
     (let ((marginalia--original-category (alist-get 'category metadata)))
       ;; using alist-get in the line above bypasses any advice on
       ;; completion-metadata-get to avoid infinite recursion
       (run-hook-with-args-until-success 'marginalia-classifiers)))))

(defun marginalia--minibuffer-setup ()
  "Setup minibuffer for `marginalia-mode'.
Remember `this-command' for annotation."
  (setq-local marginalia--this-command this-command))

;;;###autoload
(define-minor-mode marginalia-mode
  "Annotate completion candidates with richer information."
  :global t

  ;; Reset first to get a clean slate.
  (advice-remove #'completion-metadata-get #'marginalia--completion-metadata-get)
  (remove-hook 'minibuffer-setup-hook #'marginalia--minibuffer-setup)

  ;; Now add our tweaks.
  (when marginalia-mode
    ;; Ensure that we remember this-command in order to select the annotation function.
    (add-hook 'minibuffer-setup-hook #'marginalia--minibuffer-setup)

    ;; Replace the metadata function.
    (advice-add #'completion-metadata-get :before-until #'marginalia--completion-metadata-get)))

;; If you want to toggle between annotators while being in the minibuffer, the completion-system
;; should refresh the candidate list. Currently there is no support for this in marginalia, but it
;; is possible to advice the `marginalia-toggle-annotators' function with the necessary refreshing
;; logic. See the discussion in https://github.com/minad/marginalia/issues/10 for reference.
;;;###autoload
(defun marginalia-toggle-annotators ()
  "Toggle between annotators in `marginalia-annotators'."
  (interactive)
  (let ((annotators (append (cdr marginalia-annotators)
                            (list (car marginalia-annotators)))))
    ;; If `marginalia-toggle-annotators' has been invoked from inside the minibuffer, only change
    ;; the annotators locally. This is useful if the command is used as an action. If the command is
    ;; not triggered from inside the minibuffer, toggle the annotator globally. Hopefully this is
    ;; not too confusing.
    (if (minibufferp)
        (setq-local marginalia-annotators annotators)
      (setq marginalia-annotators annotators))))

(provide 'marginalia)
;;; marginalia.el ends here

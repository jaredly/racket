#lang racket/base
(require racket/list
         racket/contract
         racket/format
         racket/string
         racket/path
         net/url
         "private/git-url-scheme.rkt"
         "private/github-url.rkt")

(provide
 package-source-format?
 (contract-out
  [package-source->name+type (->* (string? (or/c #f package-source-format?))
                                  (#:complain (-> string? string? any)
                                              #:must-infer-name? boolean?
                                              #:link-dirs? boolean?)
                                  (values (or/c #f string?) (or/c #f package-source-format?)))]
  [package-source->name (->* (string?)
                             ((or/c #f package-source-format?))
                             (or/c #f string?))]
  [package-source->path (->* (string?)
                             ((or/c #f 'file 'dir 'link 'static-link))
                             path?)]))

(define rx:package-name #rx"^[-_a-zA-Z0-9]+$")
(define rx:archive #rx"[.](plt|zip|tar|tgz|tar[.]gz)$")
(define rx:git #rx"[.]git$")

(define package-source-format?
  (or/c 'name 'file 'dir 'git 'github 'clone 'file-url 'dir-url 'git-url 'link 'static-link))

(define (validate-name name complain inferred?)
  (and name
       (cond
        [(regexp-match? rx:package-name name)
         name]
        [(equal? name "")
         (complain (~a (if inferred? "inferred " "")
                       "package name is empty"))
         #f]
        [else
         (complain (~a (if inferred? "inferred " "")
                       "package name includes disallowed characters"))
         #f])))

(define (extract-archive-name name+ext complain)
  (validate-name
   (and name+ext
        (path->string
         (if (path-has-extension? name+ext #".tar.gz")
             (path-replace-extension (path-replace-extension name+ext #"") #"")
             (path-replace-extension name+ext #""))))
   complain
   #t))

(define (last-non-empty p)
  (cond
   [(null? p) #f]
   [else (or (last-non-empty (cdr p))
             (and (not (equal? "" (path/param-path (car p))))
                  (path/param-path (car p))))]))

(define (num-empty p)
  (let loop ([p (reverse p)])
    (cond
     [(null? p) 0]
     [else (if (equal? "" (path/param-path (car p)))
               (add1 (loop (cdr p)))
               0)])))

(define (extract-git-name url p complain-name)
  (let ([a (assoc 'path (url-query url))])
    (define sub (and a (cdr a) (string-split (cdr a) "/")))
    (if (pair? sub)
        (validate-name (last sub) complain-name #t)
        (let ([s (last-non-empty p)])
          (validate-name (regexp-replace #rx"[.]git$" s "") complain-name #t)))))

(define (string-and-regexp-match? rx s)
  (and (string? s)
       (regexp-match? rx s)))

(define-syntax-rule (cor v complain)
  (or v (begin complain #f)))

(define (package-source->name+type s type 
                                   #:link-dirs? [link-dirs? #f]
                                   #:complain [complain-proc void]
                                   #:must-infer-name? [must-infer-name? #f])
  ;; returns (values inferred-name inferred-type);
  ;; if `type' is given it should be returned, but name can be #f;
  ;; type should not be #f for a non-#f name
  (define (complain msg)
    (complain-proc s msg))
  (define complain-name
    (if must-infer-name? complain void))
  (define (parse-path s [type type])
    (cond
     [(if type
          (eq? type 'file)
          (and (path-string? s)
               (regexp-match rx:archive s)))
      (define name
        (and (cor (path-string? s)
                  (complain "ill-formed path"))
             (cor (regexp-match rx:archive s)
                  (complain "path does not end with a recognized archive extension"))
             (let ()
               (define-values (base name+ext dir?) (if (path-string? s)
                                                       (split-path s)
                                                       (values #f #f #f)))
               (extract-archive-name name+ext complain-name))))
      (values name 'file)]
     [(if type
          (or (eq? type 'dir) 
              (eq? type 'link)
              (eq? type 'static-link))
          (path-string? s))
      (unless (path-string? s)
        (complain "ill-formed path"))
      (define-values (base name dir?) (if (path-string? s)
                                          (split-path s)
                                          (values #f #f #f)))
      (define dir-name (and (cor (path? name) 
                                 (if (not name)
                                     (complain "no elements in path")
                                     (complain "ending path element is not a name")))
                            (path->string name)))
      (values (validate-name dir-name complain-name #t)
              (or type (and dir-name (if link-dirs? 'link 'dir))))]
     [else
      (complain "ill-formed path")
      (values #f #f)]))
  (cond
   [(if type
        (eq? type 'name)
        (regexp-match? rx:package-name s))
    (values (validate-name s complain #f) 'name)]
   [(and (eq? type 'clone)
         (not (regexp-match? #rx"^(?:https?|git(?:hub|[+]https?)?)://" s)))
    (complain "repository URL must start 'http', 'https', 'git', 'git+http', 'git+https', or 'github'")
    (values #f 'clone)]
   [(and (eq? type 'github)
         (not (regexp-match? #rx"^git(?:hub)?://" s)))
    (package-source->name+type
     (string-append "git://github.com/" s)
     'github
     #:link-dirs? link-dirs?
     #:complain complain-proc
     #:must-infer-name? must-infer-name?)]
   [(if type
        (or (eq? type 'github)
            (eq? type 'git)
            (eq? type 'git-url)
            (eq? type 'clone)
            (eq? type 'file-url)
            (eq? type 'dir-url))
        (regexp-match? #rx"^(https?|github|git([+]https?)?)://" s))
    (define url (with-handlers ([exn:fail? (lambda (exn)
                                             (complain "cannot parse URL")
                                             #f)])
                  (string->url s)))
    (define-values (name name-type)
      (if url
          (let ([p (url-path url)])
            (cond
             [(if type
                  (or (eq? type 'github)
                      (and (eq? type 'clone)
                           (equal? (url-scheme url) "github")))
                  (or (equal? (url-scheme url) "github")
                      (equal? (url-scheme url) "git")))
              (unless (or (equal? (url-scheme url) "github")
                          (equal? (url-scheme url) "git"))
                (complain "URL scheme is not 'git' or 'github'"))
              (define github?
                (or (eq? type 'github)
                    (github-url? url)))
              (define name
                (and (cor (pair? p)
                          (complain "URL path is empty"))
                     (or (not github?)
                         (cor (equal? "github.com" (url-host url))
                              (complain "URL host is not 'github.com'")))
                     (if (equal? (url-scheme url) "git")
                         ;; git://
                         (and (if github?
                                  (and
                                   (cor (or (= (length p) 2)
                                            (and (= (length p) 3)
                                                 (equal? "" (path/param-path (caddr p)))))
                                        (complain "URL does not have two path elements (name and repo)"))
                                   (cor (and (string? (path/param-path (car p)))
                                             (string? (path/param-path (cadr p))))
                                        (complain "URL includes a directory indicator as an element")))
                                  (and
                                   (cor (last-non-empty p)
                                        (complain "URL path is empty"))
                                   (cor (string? (last-non-empty p))
                                        (complain "URL path ends with a directory indicator"))
                                   (cor ((num-empty p) . < . 2)
                                        (complain "URL path ends with two empty elements"))))
                              (let ([a (assoc 'path (url-query url))])
                                (or (not a)
                                    (not (cdr a))
                                    (cor (for/and ([e (in-list (string-split (cdr a) "/"))])
                                           (not (or (equal? e ".")
                                                    (equal? e ".."))))
                                         (complain "path query includes a directory indicator"))))
                              (extract-git-name url p complain-name))
                         ;; github://
                         (let ([p (if (equal? "" (path/param-path (last p)))
                                      (reverse (cdr (reverse p)))
                                      p)])
                           (and (cor ((length p) . >= . 3)
                                     (complain "URL does not have at least three path elements"))
                                (cor (andmap string? (map path/param-path p))
                                     (complain "URL includes a directory indicator"))
                                (validate-name
                                 (if (= (length p) 3)
                                     (path/param-path (second (reverse p)))
                                     (last-non-empty p))
                                 complain-name
                                 #t))))))
              (values name (or type
                               (if github?
                                   'github
                                   'git)))]
             [(if type
                  (eq? type 'file-url)
                  (and (pair? p)
                       (path/param? (last p))
                       (string-and-regexp-match? rx:archive (path/param-path (last p)))))
              (define name
                (and (cor (pair? p)
                          (complain "URL path is empty"))
                     (cor (string-and-regexp-match? rx:archive (path/param-path (last p)))
                          (complain "URL does not end with a recognized archive extension"))
                     (extract-archive-name (last-non-empty p) complain-name)))
              (values name 'file-url)]
             [(if type
                  (or (eq? type 'git)
                      (eq? type 'git-url)
                      (eq? type 'clone))
                  (or (git-url-scheme? (url-scheme url))
                      (and (last-non-empty p)
                           (string-and-regexp-match? rx:git (last-non-empty p))
                           ((num-empty p) . < . 2))))
              (define name
                (and (cor (last-non-empty p)
                          (complain "URL path is empty"))
                     (cor ((num-empty p) . < . 2)
                          (complain "URL path ends with two empty elements"))
                     (cor (string? (last-non-empty p))
                          (complain "URL path ends with a directory indicator"))
                     (extract-git-name url p complain-name)))
              (values name (if (git-url-scheme? (url-scheme url))
                               'git-url
                               'git))]
             [else
              (define name
                (and (cor (pair? p)
                          (complain "URL path is empty"))
                     (cor (last-non-empty p)
                          (complain "URL has no non-empty path"))
                     (cor (string? (last-non-empty p))
                          (complain "URL's last path element is a directory indicator"))
                     (validate-name (last-non-empty p) complain-name #t)))
              (values name 'dir-url)]))
          (values #f #f)))
    (values (validate-name name complain-name #f)
            (or type (and name-type)))]
   [(and (not type)
         (regexp-match #rx"^file://" s))
    => (lambda (m)
         (define u (with-handlers ([exn:fail? (lambda (exn)
                                                (complain "cannot parse URL")
                                                #f)])
                     (string->url s)))
         (define query-type
           (if u
               (for/or ([q (in-list (url-query u))])
                 (and (eq? (car q) 'type)
                      (cond
                       [(equal? (cdr q) "link") 'link]
                       [(equal? (cdr q) "static-link") 'static-link]
                       [(equal? (cdr q) "file") 'file]
                       [(equal? (cdr q) "dir") 'dir]
                       [else
                        (complain "URL contains an unrecognized `type' query")
                        'error])))
               'error))
         (if (eq? query-type 'error)
             (values #f 'dir)
             ;; Note that we're ignoring other query & fragment parts, if any:
             (parse-path (url->path u) (or query-type type))))]
   [(and (not type)
         (regexp-match? #rx"^[a-zA-Z]*://" s))
    (complain "unrecognized URL scheme")
    (values #f #f)]
   [else
    (parse-path s)]))

(define (package-source->name s [given-type #f])
  (define-values (name type) (package-source->name+type s given-type))
  name)

(define (package-source->path s [type #f])
  ((if (memq type '(dir link static-link))
       path->directory-path
       values)
   (cond
    [(regexp-match? #rx"^file://" s)
     (url->path (string->url s))]
    [else
     (string->path s)])))

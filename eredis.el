;; eredis... A simple emacs interface to redis
;; See for info on the protocol http://redis.io/topics/protocol

;; By Justin Heyes-Jones 2011
;; This is released under the Gnu License v3. See http://www.gnu.org/licenses/gpl.txt

;; I addded support for editing and viewing keys as an org-table
(require 'org-table)

(defvar *redis-process* nil "Current Redis client process")
(defvar *redis-state* nil "Statue of the connection")
(defvar *redis-response* nil "Stores response of last Redis command")
(defvar *redis-timeout* 10 "Timeout on the client in seconds when waiting for Redis")

;; UTILS

(defun two-lists-to-map(lst1 lst2)
  "take a list of keys LST1 and a list of values LST2 and make a hashmap"
  (let ((retmap (make-hash-table :test 'equal)))
    (mapc (lambda (n) (puthash (car n) (cdr n) retmap))
	  (map 'list (lambda (a b) (cons a b)) lst1 lst2))
    retmap))

;; helper function from http://www.emacswiki.org/emacs/ElispCookbook#toc5
(defun chomp (str)
  "Remove leading and tailing whitespace from STR."
  (let ((s (if (symbolp str) (symbol-name str) str)))
    (replace-regexp-in-string "\\(^[[:space:]\n]*\\|[[:space:]\n]*$\\)" "" s)))

(defun insert-map(m)
  "insert a map M of key value pairs into the current buffer"
  (maphash (lambda (a b) (insert (format "%s,%s\n" a b))) m))

(defun eredis-map-keys(key-expr)
  "take a glob expression like \"user.id.*\" and return the key/values of matching keys"
  (let ((keys (eredis-keys key-expr)))
    (if keys
	(let ((values (eredis-mget keys)))
	  (two-lists-to-map keys values))
      nil)))


(defun eredis-get-response()
  "await response from redis and store it"
  (if (accept-process-output *redis-process* *redis-timeout* 0 t)
      *redis-response*
    nil))

(defun eredis-parse-multi-bulk(resp)
  "parse the redis multi bulk response RESP and return the list of results"
  (if (< (length resp) 2)
      nil
    (let ((elements (split-string resp "\r\n" t)))
      (let ((count (string-to-number (subseq (first elements) 1)))
	    (return-list nil))
	(if (> count 0)
	    (dolist (item (rest elements))
	      (if (/= ?$ (string-to-char item))
		  (setf return-list (cons item return-list)))))
	(reverse
	 return-list)))))

(defun eredis-parse-bulk(resp)
  "parse the redis bulk response RESP and return the result"
  (if (= ?$ (string-to-char resp))
      (let ((count (string-to-number (subseq resp 1))))
	(if (and (> count 0)
		 (string-match "\r\n" resp))
	    (let ((body-start (match-end 0)))
	      (when body-start
		(subseq resp body-start (+ count body-start))))
	  nil))
    nil))

(defun eredis-buffer-message(process message)
  "print a message to the redis process buffer"
  (save-excursion 
    (set-buffer (process-buffer process))
    (insert message)))

(defun eredis-sentinel(process event)
  "sentinal function for redis network process which monitors for events"
  (eredis-buffer-message process (format "sentinel event %s" event))
  (cond 
   ((string-match "open" event)
    (setq *redis-state* 'open))))

(defun eredis-filter(process string)
  "filter function for redis network process, which receives output"
  (setq *redis-response* string))

(defun eredis-delete-process()
  (when *redis-process*
    (delete-process *redis-process*)
    (setq *redis-state* 'closed)))

(defun eredis-hai(host port &optional no-wait)
  (interactive "sHost: \nsPort: \n")
  (eredis-delete-process)
  (setq *redis-state* 'opening)
  (let ((p 
	 (make-network-process :name "redis"
			       :host host
			       :service port
			       :nowait no-wait
			       :filter #'eredis-filter
			       :keepalive t
			       :linger t
			       :sentinel #'eredis-sentinel
			       :buffer (get-buffer-create "*redis*"))))
    (if p
	(progn
	  ;; When doing a blocking connect set the state to
	  ;; open. A non-nlocking connect will set the state 
	  ;; to open when the connection calls the sentinel
	  (if (null no-wait)
	      (progn
		(when (called-interactively-p)
		  (message "Redis connected"))
		(setf *redis-state* 'open)))
	  (setf *redis-process* p)))))
     
(defun eredis-kthxbye()
  "Close the connection to Redis"
  (interactive)
  (eredis-delete-process))

(defun eredis-ping()
  "Return true if you can ping the Redis server"
  (interactive)
  (if (and *redis-process* (eq *redis-state* 'open))
      (progn 
	(process-send-string *redis-process* "PING\r\n")
	(let ((resp (eredis-get-response)))
	  (if (string-match "+PONG" resp)
	      (progn
		(when (called-interactively-p)
		  (message "Pong"))
		t)
	    nil)))))

(defun eredis-get(key)
  "redis GET"
  (if (and *redis-process* (eq *redis-state* 'open))
      (progn 
	(process-send-string *redis-process* (format "GET %s\r\n" key))
	(let ((resp (eredis-get-response)))
	  (eredis-parse-bulk resp)))))

(defun eredis-info()
  (interactive)
  (if (and *redis-process* (eq *redis-state* 'open))
      (progn
	(process-send-string *redis-process* "INFO\r\n")
	(let ((resp (eredis-get-response)))
	  (eredis-buffer-message *redis-process* (eredis-parse-bulk resp))))))

; http://redis.io/commands/keys

(defun eredis-keys(pattern)
  "returns a list of keys where the key matches the provided
pattern. see the link for the style of patterns"
  (process-send-string *redis-process* (concat "KEYS " pattern "\r\n"))
  (let ((r (eredis-get-response)))
    (eredis-parse-multi-bulk r)))

; http://redis.io/commands/mget

(defun eredis-mget(keys)
  "return the values of the specified keys, or nil if not present"
  (process-send-string *redis-process* (concat "MGET " (mapconcat 'identity keys " ") "\r\n"))
  (let ((r (eredis-get-response)))
    (eredis-parse-multi-bulk r)))

(defun eredis-get-map(keys)
  "given a map M of key/value pairs, go to Redis to retrieve the values and set the 
value to whatever it is in Redis (or nil if not found)"
  (let ((num-args (1+ (hash-table-count m))))
    (let ((command (format "*%d\r\n$4\r\nMGET\r\n" num-args))
	  (key-value-string "")))
      (maphash (lambda (k v)
		 (setf key-value-string (concat key-value-string (format "$%d\r\n%s\r\n" (length k) k))))
	       m)
      (process-send-string *redis-process* (concat command key-value-string))
      (eredis-get-response)))

(defun eredis-set(k v)
  "set the key K and value V in Redis"
  (let ((command "*3\r\n$3\r\nSET\r\n")
	(key-value-string (format "$%d\r\n%s\r\n$%d\r\n%s\r\n" (length k) k (length v) v)))
    (process-send-string *redis-process* (concat command key-value-string))
    (let ((resp (eredis-get-response)))
      (if (string-match "+OK" resp)
	  t
	nil))))

(defun eredis-mset(m)
  "set the keys and values of the map M in Redis"
  (let ((num-args (1+ (* 2 (hash-table-count m)))))
    (let ((command (format "*%d\r\n$4\r\nMSET\r\n" num-args))
	  (key-value-string ""))
      (maphash (lambda (k v)
		 (setf key-value-string (concat key-value-string (format "$%d\r\n%s\r\n$%d\r\n%s\r\n" (length k) k (length v) v))))
	       m)
      (process-send-string *redis-process* (concat command key-value-string))
      (let ((resp (eredis-get-response)))
	(if (string-match "+OK" resp)
	    t
	  nil)))))

(defun eredis-mset-region(beg end delimiter) 
  "Parse the current region using DELIMITER to split each line into a key value pair which
is then sent to redis using mset"
  (interactive "*r\nsDelimiter: ")
  (let ((done nil)
	(mset-param (make-hash-table :test 'equal)))
    (save-restriction
      (narrow-to-region beg end)
      (goto-char (point-min))
      (save-excursion
	(while (not done)
	  (let ((split-line 
		 (split-string  
		  (buffer-substring (point-at-bol) (point-at-eol)) 
		  delimiter)))
	    (let ((key (first split-line))
		  (value (second split-line)))
	      (if (or (null key) (null value))
		  (setf done t)
		(progn
		  (puthash key value mset-param)
		  (next-line))))))))
    (if (> (hash-table-count mset-param) 0)
	(eredis-mset mset-param)
      nil)))

(defun eredis-org-table-from-pattern(pattern)
  "Search Redis for the pattern of keys and create an org table from the results"
  (interactive "sPattern: ")
  (let ((m (eredis-map-keys pattern)))
    (if m
	(org-table-from-map m)
      (message (format "No keys found for pattern %s" pattern)))))

(defun org-table-from-map(m)
  "Create an org-table from a map of key value pairs"
  (let ((beg (point)))
    (if (hash-table-p m)
	(progn
	  (insert-map m)
	  (org-table-convert-region beg (point))))))

(defun eredis-org-table-get-field-clean(col)
  "Get a field in org table at column COL and strip any leading or
trailing whitespace using chomp. Also strip text properties"
  (let ((field (org-table-get-field col)))
    (let ((chomped (chomp field)))
      (set-text-properties 0 (length chomped) nil chomped)
      chomped)))

(defun eredis-org-table-to-map()
  "Walk an org table and convert the first column to keys and the second 
column to values in an elisp map"
  (let ((retmap (make-hash-table :test 'equal)))
    (save-excursion
      (let ((beg (org-table-begin))
	    (end (org-table-end)))
	(goto-char beg)
	(while (> end (point))
	  (let ((key (eredis-org-table-get-field-clean 1))
		(value (eredis-org-table-get-field-clean 2)))
	    (when (and key value)
	      (puthash key value retmap)))
	  (next-line))))
    retmap))

(defun eredis-org-table-row-to-key-value-pair()
  "When point is in an org table convert the first column to a key and the second 
column to a value, returning the result as a dotted pair"
  (let ((beg (org-table-begin))
	(end (org-table-end)))
    (if (and (>= (point) beg)
	     (<= (point) end))
	(let ((key (eredis-org-table-get-field-clean 1))
	      (value (eredis-org-table-get-field-clean 2)))
	  (if (and key value)
	      (cons key value)
	    nil))
      nil)))

(defun eredis-org-table-mset()
  "with point in an org table convert the table to a map and send it to redis with mset"
  (interactive)
  (let ((m (eredis-org-table-to-map)))
    (eredis-mset m)))

(defun eredis-org-table-row-set()
  "with point in an org table set the key and value"
  (interactive)
  (let ((keyvalue (eredis-org-table-row-to-key-value-pair)))
    (eredis-set (car keyvalue) (cdr keyvalue))))

(provide 'eredis)
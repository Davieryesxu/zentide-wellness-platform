;; zentide-core
;; 
;; This smart contract implements the core functionality for the ZenTide Wellness Platform,
;; a blockchain-based wellness system that tracks, validates, and rewards users for
;; consistent meditation, yoga, and affirmation practices.
;;
;; The contract maintains user profiles, activity logs, achievement tracking, and
;; rewards distribution mechanics to incentivize consistent wellness practices.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u1000))
(define-constant ERR-USER-ALREADY-EXISTS (err u1001))
(define-constant ERR-USER-NOT-FOUND (err u1002))
(define-constant ERR-INVALID-ACTIVITY-TYPE (err u1003))
(define-constant ERR-INVALID-DURATION (err u1004))
(define-constant ERR-ACTIVITY-NOT-FOUND (err u1005))
(define-constant ERR-INVALID-VERIFICATION (err u1006))
(define-constant ERR-GOAL-ALREADY-EXISTS (err u1007))
(define-constant ERR-GOAL-NOT-FOUND (err u1008))
(define-constant ERR-CHALLENGE-NOT-FOUND (err u1009))
(define-constant ERR-ALREADY-VERIFIED (err u1010))
(define-constant ERR-ACHIEVEMENT-ALREADY-CLAIMED (err u1011))

;; Data variables
(define-data-var admin principal tx-sender)
(define-data-var verifier principal tx-sender)
(define-data-var next-activity-id uint u1)
(define-data-var next-goal-id uint u1)
(define-data-var next-challenge-id uint u1)

;; Data maps
;; User profiles storing basic user information
(define-map users 
  { user-id: principal } 
  {
    username: (string-utf8 50),
    joined-at: uint,
    total-activities: uint,
    total-duration: uint
  }
)

;; Activity types with their respective point values
(define-map activity-types
  { type-id: (string-utf8 20) }
  { 
    name: (string-utf8 50),
    points-per-minute: uint,
    description: (string-utf8 200)
  }
)

;; Activities log for tracking all user wellness activities
(define-map activities
  { activity-id: uint }
  {
    user-id: principal,
    activity-type: (string-utf8 20),
    duration-minutes: uint,
    timestamp: uint,
    is-verified: bool,
    points-earned: uint,
    notes: (optional (string-utf8 200))
  }
)

;; User activity index to help retrieve a user's activities
(define-map user-activities
  { user-id: principal }
  { activity-ids: (list 500 uint) }
)

;; Streaks tracking for each user and activity type
(define-map user-streaks
  { user-id: principal, activity-type: (string-utf8 20) }
  {
    current-streak: uint,
    longest-streak: uint,
    last-activity-date: uint
  }
)

;; Achievement definitions
(define-map achievements
  { achievement-id: (string-utf8 50) }
  {
    name: (string-utf8 50),
    description: (string-utf8 200),
    required-activity-type: (optional (string-utf8 20)),
    required-count: uint,
    required-streak: uint,
    points-reward: uint
  }
)

;; User achievements tracking
(define-map user-achievements
  { user-id: principal, achievement-id: (string-utf8 50) }
  {
    achieved-at: uint,
    is-claimed: bool
  }
)

;; Personal wellness goals
(define-map personal-goals
  { goal-id: uint }
  {
    user-id: principal,
    activity-type: (string-utf8 20),
    target-count: uint,
    target-duration: uint,
    start-date: uint,
    end-date: uint,
    is-completed: bool
  }
)

;; Community challenges
(define-map community-challenges
  { challenge-id: uint }
  {
    name: (string-utf8 50),
    description: (string-utf8 200),
    activity-type: (string-utf8 20),
    target-count: uint,
    target-duration: uint,
    start-date: uint,
    end-date: uint,
    participant-count: uint
  }
)

;; Challenge participants
(define-map challenge-participants
  { challenge-id: uint, user-id: principal }
  {
    joined-at: uint,
    current-count: uint,
    current-duration: uint,
    is-completed: bool
  }
)

;; Private functions

;; Validate if an activity type exists
(define-private (is-valid-activity-type (activity-type (string-utf8 20)))
  (is-some (map-get? activity-types { type-id: activity-type }))
)

;; Calculate points for an activity
(define-private (calculate-points (activity-type (string-utf8 20)) (duration-minutes uint))
  (match (map-get? activity-types { type-id: activity-type })
    activity-info (* (get points-per-minute activity-info) duration-minutes)
    u0  ;; Default to 0 if activity type not found
  )
)

;; Update user streak information
(define-private (update-streak (user principal) (activity-type (string-utf8 20)) (timestamp uint))
  (let (
    (day-in-seconds u86400)
    (current-date (/ timestamp day-in-seconds))
    (streak-data (default-to 
      { current-streak: u0, longest-streak: u0, last-activity-date: u0 }
      (map-get? user-streaks { user-id: user, activity-type: activity-type })))
    (last-date (/ (get last-activity-date streak-data) day-in-seconds))
    (is-consecutive (is-eq (+ last-date u1) current-date))
    (new-current-streak (if (or (is-eq (get last-activity-date streak-data) u0) is-consecutive)
                           (+ (get current-streak streak-data) u1)
                           u1))
    (new-longest-streak (if (> new-current-streak (get longest-streak streak-data))
                           new-current-streak
                           (get longest-streak streak-data)))
  )
    (map-set user-streaks
      { user-id: user, activity-type: activity-type }
      {
        current-streak: new-current-streak,
        longest-streak: new-longest-streak,
        last-activity-date: timestamp
      }
    )
    new-current-streak
  )
)

;; Add an activity ID to a user's activity list
(define-private (add-activity-to-user (user principal) (activity-id uint))
  (let (
    (current-activities (default-to { activity-ids: (list) } 
                        (map-get? user-activities { user-id: user })))
  )
    (map-set user-activities
      { user-id: user }
      { activity-ids: (append (get activity-ids current-activities) activity-id) }
    )
  )
)

;; Check if user has completed an achievement and mark it
(define-private (check-achievement (user principal) 
                                  (activity-type (string-utf8 20)) 
                                  (streak uint))
  (fold check-single-achievement
        (map-keys achievements)
        { user: user, activity-type: activity-type, streak: streak })
)

;; Check a single achievement for completion
(define-private (check-single-achievement 
                 (achievement-key { achievement-id: (string-utf8 50) })
                 (context { user: principal, activity-type: (string-utf8 20), streak: uint }))
  (let (
    (achievement (unwrap-panic (map-get? achievements achievement-key)))
    (user (get user context))
    (activity-type (get activity-type context))
    (streak (get streak context))
    (required-type (get required-activity-type achievement))
    (matches-type (or 
                   (is-none required-type) 
                   (is-eq (some activity-type) required-type)))
  )
    ;; Only process if activity type matches (or no specific type required)
    (if matches-type
      (let (
        (total-activities (get total-activities 
                             (default-to { total-activities: u0, total-duration: u0 } 
                                        (map-get? users { user-id: user }))))
        (meets-count (>= total-activities (get required-count achievement)))
        (meets-streak (>= streak (get required-streak achievement)))
        (already-achieved (is-some (map-get? user-achievements 
                                          { user-id: user, 
                                            achievement-id: (get achievement-id achievement-key) })))
      )
        ;; If achievement criteria met and not already achieved, record it
        (if (and (and meets-count meets-streak) (not already-achieved))
          (begin
            (map-set user-achievements
              { user-id: user, achievement-id: (get achievement-id achievement-key) }
              { achieved-at: (unwrap-panic (get-block-info? time u0)), is-claimed: false }
            )
            context
          )
          context
        )
      )
      context
    )
  )
)

;; Read-only functions

;; Get user profile information
(define-read-only (get-user-profile (user principal))
  (map-get? users { user-id: user })
)

;; Get user activity history
(define-read-only (get-user-activities (user principal))
  (map-get? user-activities { user-id: user })
)

;; Get activity details by ID
(define-read-only (get-activity (activity-id uint))
  (map-get? activities { activity-id: activity-id })
)

;; Get streak info for a user and activity type
(define-read-only (get-user-streak (user principal) (activity-type (string-utf8 20)))
  (map-get? user-streaks { user-id: user, activity-type: activity-type })
)

;; Get all user achievements
(define-read-only (get-user-achievements (user principal))
  (let (
    (achievement-keys (map-keys achievements))
  )
    (filter is-some 
      (map get-user-single-achievement 
           (map 
             (lambda (achievement-key) 
               (get achievement-id achievement-key)) 
             achievement-keys
           )
      )
    )
  )
)

;; Helper to get a single user achievement
(define-read-only (get-user-single-achievement (achievement-id (string-utf8 50)))
  (map-get? user-achievements { user-id: tx-sender, achievement-id: achievement-id })
)

;; Get personal goal details
(define-read-only (get-personal-goal (goal-id uint))
  (map-get? personal-goals { goal-id: goal-id })
)

;; Get challenge details
(define-read-only (get-challenge (challenge-id uint))
  (map-get? community-challenges { challenge-id: challenge-id })
)

;; Get user's challenge participation
(define-read-only (get-challenge-participation (challenge-id uint) (user principal))
  (map-get? challenge-participants { challenge-id: challenge-id, user-id: user })
)

;; Public functions

;; Register a new user
(define-public (register-user (username (string-utf8 50)))
  (let (
    (user tx-sender)
    (user-exists (is-some (map-get? users { user-id: user })))
  )
    (asserts! (not user-exists) ERR-USER-ALREADY-EXISTS)
    (map-set users
      { user-id: user }
      {
        username: username,
        joined-at: (unwrap-panic (get-block-info? time u0)),
        total-activities: u0,
        total-duration: u0
      }
    )
    (ok true)
  )
)

;; Add a new activity type (admin only)
(define-public (add-activity-type (type-id (string-utf8 20)) 
                                 (name (string-utf8 50)) 
                                 (points-per-minute uint)
                                 (description (string-utf8 200)))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) ERR-NOT-AUTHORIZED)
    (map-set activity-types
      { type-id: type-id }
      {
        name: name,
        points-per-minute: points-per-minute,
        description: description
      }
    )
    (ok true)
  )
)

;; Log a wellness activity
(define-public (log-activity (activity-type (string-utf8 20)) 
                           (duration-minutes uint)
                           (notes (optional (string-utf8 200))))
  (let (
    (user tx-sender)
    (user-exists (is-some (map-get? users { user-id: user })))
    (activity-type-valid (is-valid-activity-type activity-type))
    (current-time (unwrap-panic (get-block-info? time u0)))
    (activity-id (var-get next-activity-id))
    (points (calculate-points activity-type duration-minutes))
    (user-data (default-to 
                { username: "", joined-at: u0, total-activities: u0, total-duration: u0 }
                (map-get? users { user-id: user })))
  )
    ;; Validate input
    (asserts! user-exists ERR-USER-NOT-FOUND)
    (asserts! activity-type-valid ERR-INVALID-ACTIVITY-TYPE)
    (asserts! (> duration-minutes u0) ERR-INVALID-DURATION)
    
    ;; Record the activity
    (map-set activities
      { activity-id: activity-id }
      {
        user-id: user,
        activity-type: activity-type,
        duration-minutes: duration-minutes,
        timestamp: current-time,
        is-verified: false,
        points-earned: points,
        notes: notes
      }
    )
    
    ;; Update user's activity list
    (add-activity-to-user user activity-id)
    
    ;; Update user stats
    (map-set users
      { user-id: user }
      {
        username: (get username user-data),
        joined-at: (get joined-at user-data),
        total-activities: (+ (get total-activities user-data) u1),
        total-duration: (+ (get total-duration user-data) duration-minutes)
      }
    )
    
    ;; Update streak information
    (let (
      (new-streak (update-streak user activity-type current-time))
    )
      ;; Check achievements after updating streak
      (check-achievement user activity-type new-streak)
      
      ;; Increment activity ID for next use
      (var-set next-activity-id (+ activity-id u1))
      
      (ok activity-id)
    )
  )
)

;; Verify an activity (by verifier)
(define-public (verify-activity (activity-id uint))
  (let (
    (activity (map-get? activities { activity-id: activity-id }))
  )
    ;; Validate request
    (asserts! (is-eq tx-sender (var-get verifier)) ERR-NOT-AUTHORIZED)
    (asserts! (is-some activity) ERR-ACTIVITY-NOT-FOUND)
    (asserts! (not (get is-verified (unwrap-panic activity))) ERR-ALREADY-VERIFIED)
    
    ;; Update activity verification status
    (map-set activities
      { activity-id: activity-id }
      (merge (unwrap-panic activity) { is-verified: true })
    )
    
    (ok true)
  )
)

;; Set a personal wellness goal
(define-public (set-personal-goal (activity-type (string-utf8 20)) 
                                 (target-count uint) 
                                 (target-duration uint)
                                 (end-date uint))
  (let (
    (user tx-sender)
    (user-exists (is-some (map-get? users { user-id: user })))
    (activity-type-valid (is-valid-activity-type activity-type))
    (current-time (unwrap-panic (get-block-info? time u0)))
    (goal-id (var-get next-goal-id))
  )
    ;; Validate input
    (asserts! user-exists ERR-USER-NOT-FOUND)
    (asserts! activity-type-valid ERR-INVALID-ACTIVITY-TYPE)
    (asserts! (> end-date current-time) ERR-INVALID-DURATION)
    
    ;; Create the goal
    (map-set personal-goals
      { goal-id: goal-id }
      {
        user-id: user,
        activity-type: activity-type,
        target-count: target-count,
        target-duration: target-duration,
        start-date: current-time,
        end-date: end-date,
        is-completed: false
      }
    )
    
    ;; Increment goal ID for next use
    (var-set next-goal-id (+ goal-id u1))
    
    (ok goal-id)
  )
)

;; Create a community challenge (admin only)
(define-public (create-community-challenge (name (string-utf8 50))
                                          (description (string-utf8 200))
                                          (activity-type (string-utf8 20))
                                          (target-count uint)
                                          (target-duration uint)
                                          (start-date uint)
                                          (end-date uint))
  (let (
    (challenge-id (var-get next-challenge-id))
    (current-time (unwrap-panic (get-block-info? time u0)))
    (activity-type-valid (is-valid-activity-type activity-type))
  )
    ;; Validate input
    (asserts! (is-eq tx-sender (var-get admin)) ERR-NOT-AUTHORIZED)
    (asserts! activity-type-valid ERR-INVALID-ACTIVITY-TYPE)
    (asserts! (> end-date start-date) ERR-INVALID-DURATION)
    (asserts! (>= start-date current-time) ERR-INVALID-DURATION)
    
    ;; Create the challenge
    (map-set community-challenges
      { challenge-id: challenge-id }
      {
        name: name,
        description: description,
        activity-type: activity-type,
        target-count: target-count,
        target-duration: target-duration,
        start-date: start-date,
        end-date: end-date,
        participant-count: u0
      }
    )
    
    ;; Increment challenge ID for next use
    (var-set next-challenge-id (+ challenge-id u1))
    
    (ok challenge-id)
  )
)

;; Join a community challenge
(define-public (join-challenge (challenge-id uint))
  (let (
    (user tx-sender)
    (user-exists (is-some (map-get? users { user-id: user })))
    (challenge (map-get? community-challenges { challenge-id: challenge-id }))
    (current-time (unwrap-panic (get-block-info? time u0)))
    (already-joined (is-some (map-get? challenge-participants 
                                     { challenge-id: challenge-id, user-id: user })))
  )
    ;; Validate input
    (asserts! user-exists ERR-USER-NOT-FOUND)
    (asserts! (is-some challenge) ERR-CHALLENGE-NOT-FOUND)
    (asserts! (not already-joined) ERR-USER-ALREADY-EXISTS)
    (asserts! (<= current-time (get end-date (unwrap-panic challenge))) ERR-INVALID-DURATION)
    
    ;; Record participation
    (map-set challenge-participants
      { challenge-id: challenge-id, user-id: user }
      {
        joined-at: current-time,
        current-count: u0,
        current-duration: u0,
        is-completed: false
      }
    )
    
    ;; Update participant count
    (map-set community-challenges
      { challenge-id: challenge-id }
      (merge (unwrap-panic challenge)
            { participant-count: (+ (get participant-count (unwrap-panic challenge)) u1) })
    )
    
    (ok true)
  )
)

;; Claim achievement reward
(define-public (claim-achievement-reward (achievement-id (string-utf8 50)))
  (let (
    (user tx-sender)
    (user-achievement (map-get? user-achievements { user-id: user, achievement-id: achievement-id }))
    (achievement (map-get? achievements { achievement-id: achievement-id }))
  )
    ;; Validate claim
    (asserts! (is-some user-achievement) ERR-ACHIEVEMENT-NOT-FOUND)
    (asserts! (is-some achievement) ERR-ACHIEVEMENT-NOT-FOUND)
    (asserts! (not (get is-claimed (unwrap-panic user-achievement))) ERR-ACHIEVEMENT-ALREADY-CLAIMED)
    
    ;; Mark as claimed
    (map-set user-achievements
      { user-id: user, achievement-id: achievement-id }
      (merge (unwrap-panic user-achievement) { is-claimed: true })
    )
    
    ;; Achievement reward logic would go here
    ;; For example, issuing tokens or unlocking content
    
    (ok (get points-reward (unwrap-panic achievement)))
  )
)

;; Update admin
(define-public (set-admin (new-admin principal))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) ERR-NOT-AUTHORIZED)
    (var-set admin new-admin)
    (ok true)
  )
)

;; Update verifier
(define-public (set-verifier (new-verifier principal))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) ERR-NOT-AUTHORIZED)
    (var-set verifier new-verifier)
    (ok true)
  )
)

;; Add a new achievement (admin only)
(define-public (add-achievement (achievement-id (string-utf8 50))
                              (name (string-utf8 50))
                              (description (string-utf8 200))
                              (required-activity-type (optional (string-utf8 20)))
                              (required-count uint)
                              (required-streak uint)
                              (points-reward uint))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) ERR-NOT-AUTHORIZED)
    (map-set achievements
      { achievement-id: achievement-id }
      {
        name: name,
        description: description,
        required-activity-type: required-activity-type,
        required-count: required-count,
        required-streak: required-streak,
        points-reward: points-reward
      }
    )
    (ok true)
  )
)
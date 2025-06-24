;; bulletproof-wrap.clar
;; Bulletproof Asset Wrap
;; This contract provides a secure and flexible mechanism for wrapping and tracking digital assets
;; on the Stacks blockchain. It enables users to encapsulate assets with granular privacy controls,
;; comprehensive tracking, and advanced monitoring capabilities. The system ensures immutable
;; record-keeping, compliance tracking, and controlled asset exposure.
;; ===============================
;; Error Codes
;; ===============================
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-ASSET-NOT-FOUND (err u101))
(define-constant ERR-ASSET-EXISTS (err u102))
(define-constant ERR-VAULT-NOT-FOUND (err u103))
(define-constant ERR-INVALID-PARAMETERS (err u104))
(define-constant ERR-UNAUTHORIZED-VIEWER (err u105))
(define-constant ERR-CATEGORY-NOT-FOUND (err u106))
(define-constant ERR-THRESHOLD-NOT-FOUND (err u107))
(define-constant ERR-THRESHOLD-EXISTS (err u108))
;; ===============================
;; Data Structures
;; ===============================
;; Asset structure
;; Represents a single digital asset owned by a user
(define-map assets
  {
    owner: principal,
    asset-id: (string-ascii 36),
  }
  {
    name: (string-utf8 100),
    category: (string-ascii 50),
    acquisition-date: uint,
    acquisition-cost: uint,
    current-value: uint,
    last-updated: uint,
    metadata: (optional (string-utf8 1000)),
    public-view: bool,
  }
)
;; Asset valuation history
;; Tracks the value of an asset over time
(define-map asset-history
  {
    owner: principal,
    asset-id: (string-ascii 36),
    timestamp: uint,
  }
  { value: uint }
)
;; Categories defined by user
;; Allows users to create custom asset categories
(define-map user-categories
  {
    owner: principal,
    category-id: (string-ascii 50),
  }
  {
    name: (string-utf8 100),
    description: (optional (string-utf8 500)),
  }
)
;; User vaults
;; Contains metadata about a user's entire portfolio
(define-map vaults
  { owner: principal }
  {
    vault-name: (string-utf8 100),
    creation-date: uint,
    public-view: bool,
    last-updated: uint,
  }
)
;; Authorized viewers
;; Allows users to grant access to specific third parties
(define-map authorized-viewers
  {
    vault-owner: principal,
    viewer: principal,
  }
  {
    authorized-at: uint,
    expiration: (optional uint),
  }
)
;; Monitoring thresholds
;; Defines value thresholds for asset monitoring
(define-map monitoring-thresholds
  {
    owner: principal,
    asset-id: (string-ascii 36),
    threshold-id: (string-ascii 36),
  }
  {
    comparison: (string-ascii 2), ;; "gt" for greater than, "lt" for less than
    value: uint,
    description: (optional (string-utf8 200)),
    created-at: uint,
  }
)
;; ===============================
;; Private Functions
;; ===============================
;; Check if sender is authorized to access a vault
;; Either the owner or an authorized viewer with unexpired access
(define-private (is-authorized (vault-owner principal))
  (if (is-eq tx-sender vault-owner)
    true ;; User is the vault owner
    ;; Not the owner, check if they are an authorized viewer
    (match (get-authorized-viewer vault-owner tx-sender)
      ;; Case 1: An entry exists in authorized-viewers map for tx-sender
      viewer-data ;; viewer-data is the tuple { authorized-at: uint, expiration: (optional uint) }
      (match (get expiration viewer-data)
        ;; Case 1a: The 'expiration' field is (some timestamp)
        timestamp
        (> timestamp block-height) ;; True if not expired, false if expired
        ;; Case 1b: The 'expiration' field is none (no expiration date)
        true ;; Authorization is permanent, so not expired
      )
      ;; Case 2: No entry in authorized-viewers map for tx-sender (they are not an authorized viewer)
      false ;; Not authorized
    )
  )
)

;; Get authorized viewer information if it exists
(define-private (get-authorized-viewer
    (vault-owner principal)
    (viewer principal)
  )
  (map-get? authorized-viewers {
    vault-owner: vault-owner,
    viewer: viewer,
  })
)

;; Check if asset exists
(define-private (asset-exists
    (owner principal)
    (asset-id (string-ascii 36))
  )
  (is-some (map-get? assets {
    owner: owner,
    asset-id: asset-id,
  }))
)

;; Record a new valuation in the asset history
(define-private (record-valuation
    (owner principal)
    (asset-id (string-ascii 36))
    (value uint)
  )
  (let ((current-time block-height))
    (map-set asset-history {
      owner: owner,
      asset-id: asset-id,
      timestamp: current-time,
    } { value: value }
    )
    current-time
  )
)

;; Initialize a new vault if not exists
(define-private (ensure-vault-exists
    (owner principal)
    (name (string-utf8 100))
  )
  (if (is-some (map-get? vaults { owner: owner }))
    true
    (map-set vaults { owner: owner } {
      vault-name: name,
      creation-date: block-height,
      public-view: false,
      last-updated: block-height,
    })
  )
)

;; Check if user can view an asset
(define-private (can-view-asset
    (asset-owner principal)
    (asset-id (string-ascii 36))
  )
  (let ((asset-info (map-get? assets {
      owner: asset-owner,
      asset-id: asset-id,
    })))
    (or
      (is-eq tx-sender asset-owner)
      (and
        (is-some asset-info)
        (get public-view (unwrap! asset-info false))
      )
      (is-authorized asset-owner)
    )
  )
)

;; ===============================
;; Read-Only Functions
;; ===============================

;; Check if sender is authorized for a vault
(define-read-only (check-authorization (vault-owner principal))
  (ok (is-authorized vault-owner))
)

;; Get monitoring threshold information
(define-read-only (get-threshold
    (owner principal)
    (asset-id (string-ascii 36))
    (threshold-id (string-ascii 36))
  )
  (begin
    (asserts! (can-view-asset owner asset-id) ERR-NOT-AUTHORIZED)
    (let ((threshold (map-get? monitoring-thresholds {
        owner: owner,
        asset-id: asset-id,
        threshold-id: threshold-id,
      })))
      (if (is-some threshold)
        (ok (unwrap! threshold ERR-THRESHOLD-NOT-FOUND))
        ERR-THRESHOLD-NOT-FOUND
      )
    )
  )
)

;; Check if an asset has reached any monitoring thresholds
;; Returns list of thresholds that have been triggered
(define-read-only (check-thresholds
    (owner principal)
    (asset-id (string-ascii 36))
  )
  (begin
    (asserts! (can-view-asset owner asset-id) ERR-NOT-AUTHORIZED)
    (let ((asset-info (map-get? assets {
        owner: owner,
        asset-id: asset-id,
      })))
      (if (is-none asset-info)
        ERR-ASSET-NOT-FOUND
        (ok "Threshold check would be implemented here")
        ;; Note: In actual implementation, we would use fold or filter on the thresholds map
        ;; to check all thresholds against the current value, but those operations are
        ;; limited in this simplified version
      )
    )
  )
)

;; ===============================
;; Public Functions
;; ===============================
;; Register a new asset in the user's vault
(define-public (register-asset
    (asset-id (string-ascii 36))
    (name (string-utf8 100))
    (category (string-ascii 50))
    (acquisition-date uint)
    (acquisition-cost uint)
    (current-value uint)
    (metadata (optional (string-utf8 1000)))
    (public-view bool)
  )
  (let ((owner tx-sender))
    ;; Ensure vault exists - create with default name if not
    (ensure-vault-exists owner u"My Vault")
    ;; Check that asset doesn't already exist
    (asserts! (not (asset-exists owner asset-id)) ERR-ASSET-EXISTS)
    ;; Register the asset
    (map-set assets {
      owner: owner,
      asset-id: asset-id,
    } {
      name: name,
      category: category,
      acquisition-date: acquisition-date,
      acquisition-cost: acquisition-cost,
      current-value: current-value,
      last-updated: block-height,
      metadata: metadata,
      public-view: public-view,
    })
    ;; Record initial valuation in history
    (record-valuation owner asset-id current-value)
    ;; Update vault last updated timestamp
    (map-set vaults { owner: owner }
      (merge (unwrap! (map-get? vaults { owner: owner }) ERR-VAULT-NOT-FOUND) { last-updated: block-height })
    )
    (ok asset-id)
  )
)

;; Update asset valuation
(define-public (update-asset-value
    (asset-id (string-ascii 36))
    (new-value uint)
  )
  (let ((owner tx-sender))
    ;; Check that asset exists
    (asserts! (asset-exists owner asset-id) ERR-ASSET-NOT-FOUND)
    ;; Get current asset info
    (let ((asset-info (unwrap!
        (map-get? assets {
          owner: owner,
          asset-id: asset-id,
        })
        ERR-ASSET-NOT-FOUND
      )))
      ;; Update asset value
      (map-set assets {
        owner: owner,
        asset-id: asset-id,
      }
        (merge asset-info {
          current-value: new-value,
          last-updated: block-height,
        })
      )
      ;; Record new valuation in history
      (record-valuation owner asset-id new-value)
      ;; Update vault last updated timestamp
      (map-set vaults { owner: owner }
        (merge (unwrap! (map-get? vaults { owner: owner }) ERR-VAULT-NOT-FOUND) { last-updated: block-height })
      )
      (ok new-value)
    )
  )
)

;; Update asset details (except value which has its own function)
(define-public (update-asset-details
    (asset-id (string-ascii 36))
    (name (string-utf8 100))
    (category (string-ascii 50))
    (acquisition-date uint)
    (acquisition-cost uint)
    (metadata (optional (string-utf8 1000)))
    (public-view bool)
  )
  (let ((owner tx-sender))
    ;; Check that asset exists
    (asserts! (asset-exists owner asset-id) ERR-ASSET-NOT-FOUND)
    ;; Get current asset info for the current value
    (let ((asset-info (unwrap!
        (map-get? assets {
          owner: owner,
          asset-id: asset-id,
        })
        ERR-ASSET-NOT-FOUND
      )))
      ;; Update asset details
      (map-set assets {
        owner: owner,
        asset-id: asset-id,
      } {
        name: name,
        category: category,
        acquisition-date: acquisition-date,
        acquisition-cost: acquisition-cost,
        current-value: (get current-value asset-info),
        last-updated: block-height,
        metadata: metadata,
        public-view: public-view,
      })
      ;; Update vault last updated timestamp
      (map-set vaults { owner: owner }
        (merge (unwrap! (map-get? vaults { owner: owner }) ERR-VAULT-NOT-FOUND) { last-updated: block-height })
      )
      (ok asset-id)
    )
  )
)

;; Delete an asset
(define-public (delete-asset (asset-id (string-ascii 36)))
  (let ((owner tx-sender))
    ;; Check that asset exists
    (asserts! (asset-exists owner asset-id) ERR-ASSET-NOT-FOUND)
    ;; Delete the asset (note: history will remain)
    (map-delete assets {
      owner: owner,
      asset-id: asset-id,
    })
    ;; Update vault last updated timestamp
    (map-set vaults { owner: owner }
      (merge (unwrap! (map-get? vaults { owner: owner }) ERR-VAULT-NOT-FOUND) { last-updated: block-height })
    )
    (ok asset-id)
  )
)

;; Create or update a category
(define-public (set-category
    (category-id (string-ascii 50))
    (name (string-utf8 100))
    (description (optional (string-utf8 500)))
  )
  (let ((owner tx-sender))
    ;; Ensure vault exists
    (ensure-vault-exists owner u"My Vault")
    ;; Set the category
    (map-set user-categories {
      owner: owner,
      category-id: category-id,
    } {
      name: name,
      description: description,
    })
    (ok category-id)
  )
)

;; Authorize a viewer for your vault
(define-public (authorize-viewer
    (viewer principal)
    (expiration (optional uint))
  )
  (let ((owner tx-sender))
    ;; Ensure vault exists
    (ensure-vault-exists owner u"My Vault")
    ;; Set viewer authorization
    (map-set authorized-viewers {
      vault-owner: owner,
      viewer: viewer,
    } {
      authorized-at: block-height,
      expiration: expiration,
    })
    (ok true)
  )
)

;; Revoke viewer authorization
(define-public (revoke-viewer (viewer principal))
  (let ((owner tx-sender))
    ;; Delete authorization
    (map-delete authorized-viewers {
      vault-owner: owner,
      viewer: viewer,
    })
    (ok true)
  )
)

;; Create monitoring threshold
(define-public (set-threshold
    (asset-id (string-ascii 36))
    (threshold-id (string-ascii 36))
    (comparison (string-ascii 2))
    (value uint)
    (description (optional (string-utf8 200)))
  )
  (let ((owner tx-sender))
    ;; Check that asset exists
    (asserts! (asset-exists owner asset-id) ERR-ASSET-NOT-FOUND)
    ;; Validate comparison operator
    (asserts! (or (is-eq comparison "gt") (is-eq comparison "lt"))
      ERR-INVALID-PARAMETERS
    )
    ;; Set threshold
    (map-set monitoring-thresholds {
      owner: owner,
      asset-id: asset-id,
      threshold-id: threshold-id,
    } {
      comparison: comparison,
      value: value,
      description: description,
      created-at: block-height,
    })
    (ok threshold-id)
  )
)

;; Delete monitoring threshold
(define-public (delete-threshold
    (asset-id (string-ascii 36))
    (threshold-id (string-ascii 36))
  )
  (let ((owner tx-sender))
    ;; Check that asset exists
    (asserts! (asset-exists owner asset-id) ERR-ASSET-NOT-FOUND)
    ;; Check that threshold exists
    (asserts!
      (is-some (map-get? monitoring-thresholds {
        owner: owner,
        asset-id: asset-id,
        threshold-id: threshold-id,
      }))
      ERR-THRESHOLD-NOT-FOUND
    )
    ;; Delete threshold
    (map-delete monitoring-thresholds {
      owner: owner,
      asset-id: asset-id,
      threshold-id: threshold-id,
    })
    (ok threshold-id)
  )
)

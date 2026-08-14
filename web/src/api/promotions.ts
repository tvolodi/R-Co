import { client } from './client'

// ── Promotion Review types (PRM-02 – PRM-05) ──────────────────────────────────

/** Plan entry shape — canonical JSON object keys sorted lexicographically */
export interface PlanEntry {
  type: string
  id: string
  change_kind: 'added' | 'modified' | 'removed'
  before: string | null
  after: string | null
}

/** Promotion plan — array of plan entries */
export interface PromotionPlan {
  entries: PlanEntry[]
}

/** Conflict item inside a PROMOTION_CONFLICT response */
export interface PromotionConflictItem {
  process_key: string
  target_definition_id: string
  target_version: number
  source_change: string
  target_change: string
}

/** HTTP 409 PROMOTION_CONFLICT response body */
export interface PromotionConflictError {
  error: 'PROMOTION_CONFLICT'
  message: string
  conflicts: PromotionConflictItem[]
}

/** HTTP 409 PLAN_DIGEST_MISMATCH response body */
export interface PlanDigestMismatchError {
  error: 'PLAN_DIGEST_MISMATCH'
  message: string
}

/** HTTP 403 SELF_APPROVAL_FORBIDDEN response body */
export interface SelfApprovalForbiddenError {
  error: 'SELF_APPROVAL_FORBIDDEN'
  message: string
}

/** HTTP 400 INVALID_REVIEW_TRANSITION response body */
export interface InvalidReviewTransitionError {
  error: 'INVALID_REVIEW_TRANSITION'
  message: string
}

/** Review status — six-state promotion review state machine (PRM-04) */
export type ReviewStatus =
  | 'pending_review'
  | 'approved'
  | 'rejected'
  | 'applied'
  | 'failed'
  | 'superseded'

/** Stored promotion review record (PRM-04) */
export interface PromotionReview {
  id: string
  tenant_id: string
  plan_digest: string
  def_type: string
  def_id: string
  serialised_plan: string
  status: ReviewStatus
  requested_by: string
  approved_by: string | null
  approved_at: string | null
  superseded_by: string | null
  row_version: number
  created_at: string
  updated_at: string
}

/** GET /api/v1/promotions/{id}/context response */
export interface PromotionContext {
  review: PromotionReview
  /** Parsed serialised_plan — canonical JSON */
  plan: PromotionPlan
  /** Human-readable digest verification status */
  digest_verified: boolean
  /** NEEDS_REVIEW package artifact assertions */
  assertions: Array<{
    artifact_id: string
    assertion_type: string
    passed: boolean
  }>
}

/** POST /api/v1/promotions/{id}/approve body */
export interface ApprovePromotionRequest {
  plan_digest: string
  approved_by: string
}

/** POST /api/v1/promotions/{id}/apply body */
export interface ApplyPromotionRequest {
  plan_digest: string
}

// ── API client ─────────────────────────────────────────────────────────────────

export const promotionsApi = {
  /**
   * GET /api/v1/promotions/{reviewId}/context
   * Returns the stored plan, digest, and review context for a given review.
   */
  getContext: (reviewId: string) =>
    client.get<PromotionContext>(`/api/v1/promotions/${reviewId}/context`),

  /**
   * POST /api/v1/promotions/{reviewId}/approve
   * Approves a pending promotion review.
   * Gate: approved_by != requested_by (HTTP 403), status == pending_review (HTTP 400),
   *       plan_digest matches stored (HTTP 409).
   */
  approve: (reviewId: string, body: ApprovePromotionRequest) =>
    client.post<void>(`/api/v1/promotions/${reviewId}/approve`, body),

  /**
   * POST /api/v1/promotions/{reviewId}/reject
   * Rejects a pending promotion review.
   * Gate: status == pending_review (HTTP 400).
   */
  reject: (reviewId: string) =>
    client.post<void>(`/api/v1/promotions/${reviewId}/reject`, {}),

  /**
   * POST /api/v1/promotions/{reviewId}/apply
   * Applies an approved promotion.
   * Gate: status == approved (HTTP 400), plan_digest matches stored (HTTP 409).
   * No bypass parameter — non-skippable gate (PRM-05 AC3).
   */
  apply: (reviewId: string, body: ApplyPromotionRequest) =>
    client.post<void>(`/api/v1/promotions/${reviewId}/apply`, body),
}

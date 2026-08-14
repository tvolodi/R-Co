/** TanStack Query hooks for promotion reviews (PRM-02 – PRM-05) */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { promotionsApi } from '@/api/promotions'
import { queryKeys } from '@/api/queryKeys'
import type {
  ApprovePromotionRequest,
  ApplyPromotionRequest,
} from '@/api/promotions'

export const promotionKeys = {
  all: queryKeys.promotions.all,
  context: queryKeys.promotions.context,
}

/** Fetch GET /api/v1/promotions/{reviewId}/context */
export function usePromotionContext(reviewId: string) {
  return useQuery({
    queryKey: promotionKeys.context(reviewId),
    queryFn: () => promotionsApi.getContext(reviewId),
    enabled: !!reviewId,
  })
}

/** Mutation: POST /api/v1/promotions/{reviewId}/approve */
export function useApprovePromotion() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ reviewId, body }: { reviewId: string; body: ApprovePromotionRequest }) =>
      promotionsApi.approve(reviewId, body),
    onSuccess: (_data, { reviewId }) => {
      void qc.invalidateQueries({ queryKey: promotionKeys.context(reviewId) })
    },
  })
}

/** Mutation: POST /api/v1/promotions/{reviewId}/reject */
export function useRejectPromotion() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (reviewId: string) => promotionsApi.reject(reviewId),
    onSuccess: (_data, reviewId) => {
      void qc.invalidateQueries({ queryKey: promotionKeys.context(reviewId) })
    },
  })
}

/** Mutation: POST /api/v1/promotions/{reviewId}/apply */
export function useApplyPromotion() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ reviewId, body }: { reviewId: string; body: ApplyPromotionRequest }) =>
      promotionsApi.apply(reviewId, body),
    onSuccess: (_data, { reviewId }) => {
      void qc.invalidateQueries({ queryKey: promotionKeys.context(reviewId) })
    },
  })
}

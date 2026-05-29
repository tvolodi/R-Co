/* Form field reference example (Lego Type B sub-pattern).
 *
 * This is a hand-written reference — NOT codegen output. CODE-DESIGNER and
 * FRONTEND-DEV copy these patterns when a requirement adds a new form input.
 * Reading this beats re-deriving the conventions from a long style guide
 * because every line shows the exact wiring the linters (F010/F020/F030/F050)
 * and the design system expect.
 *
 * Patterns covered:
 *   1. Controlled text input wired into React Hook Form
 *   2. Controlled select wired into React Hook Form
 *   3. Server-side error surface via Zod validation
 *   4. Role-gated field that is hidden (never disabled) for the wrong role
 *   5. Submit button using useMutation, invalidating a queryKeys factory entry
 */
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useForm, type SubmitHandler } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { apiClient } from '../../api/client'
import { queryKeys } from '../../api/queryKeys'
import { useCurrentUserRole } from '../../auth/useCurrentUserRole'

// 1) Zod schema — single source of truth for shape + validation.
const PolicyDraftSchema = z.object({
  name: z.string().min(1, 'Name is required').max(120),
  visibility: z.enum(['PRIVATE', 'TENANT', 'PUBLIC']),
  // Optional field only present for admins; schema accepts undefined.
  adminNotes: z.string().max(2000).optional(),
})
type PolicyDraft = z.infer<typeof PolicyDraftSchema>

interface PolicyFormProps {
  tenantId: string
  onCreated?: (policyId: string) => void
}

export function PolicyForm({ tenantId, onCreated }: PolicyFormProps) {
  const queryClient = useQueryClient()
  const role = useCurrentUserRole()
  const isAdmin = role === 'PLATFORM_ADMIN'

  const {
    register,
    handleSubmit,
    reset,
    setError,
    formState: { errors, isSubmitting },
  } = useForm<PolicyDraft>({
    resolver: zodResolver(PolicyDraftSchema),
    defaultValues: { visibility: 'TENANT' },
  })

  // 5) Mutation — uses queryKeys factory for invalidation (F030 enforces).
  const createMutation = useMutation({
    mutationFn: (payload: PolicyDraft) =>
      apiClient.post(`/api/v1/tenants/${tenantId}/policies`, payload).then(r => r.data),
    onSuccess: created => {
      queryClient.invalidateQueries({ queryKey: queryKeys.policies.list({ tenantId }) })
      reset()
      onCreated?.(created.id)
    },
    onError: (err: unknown) => {
      // 3) Server-side validation surfaces via setError on the specific field.
      if (
        typeof err === 'object' &&
        err !== null &&
        'response' in err &&
        (err as { response?: { status?: number } }).response?.status === 422
      ) {
        const body = (err as { response: { data?: { field?: string; message?: string } } })
          .response.data
        if (body?.field && body?.message) {
          setError(body.field as keyof PolicyDraft, { message: body.message })
        }
      }
    },
  })

  const onSubmit: SubmitHandler<PolicyDraft> = data => createMutation.mutate(data)

  return (
    <form onSubmit={handleSubmit(onSubmit)} noValidate>
      {/* 1) Controlled text input — register() wires value + onChange. */}
      <label className="form-field">
        <span className="form-field__label">Name</span>
        <input
          type="text"
          autoComplete="off"
          aria-invalid={errors.name ? 'true' : undefined}
          {...register('name')}
        />
        {errors.name && (
          <span role="alert" className="form-field__error">
            {errors.name.message}
          </span>
        )}
      </label>

      {/* 2) Controlled select — same register() wiring; options are static here. */}
      <label className="form-field">
        <span className="form-field__label">Visibility</span>
        <select aria-invalid={errors.visibility ? 'true' : undefined} {...register('visibility')}>
          <option value="PRIVATE">Private</option>
          <option value="TENANT">Tenant</option>
          <option value="PUBLIC">Public</option>
        </select>
        {errors.visibility && (
          <span role="alert" className="form-field__error">
            {errors.visibility.message}
          </span>
        )}
      </label>

      {/* 4) Role-gated field — HIDDEN for non-admins, never just disabled.
              Lint F050 forbids `disabled={!isAdmin}`. */}
      {isAdmin && (
        <label className="form-field">
          <span className="form-field__label">Admin notes</span>
          <textarea rows={3} {...register('adminNotes')} />
          {errors.adminNotes && (
            <span role="alert" className="form-field__error">
              {errors.adminNotes.message}
            </span>
          )}
        </label>
      )}

      {/* Form-level error from server-side rejection that wasn't field-specific. */}
      {createMutation.isError && !errors.name && !errors.visibility && (
        <p role="alert" className="form__error">
          Could not save policy. Please retry.
        </p>
      )}

      <div className="form__actions">
        <button type="submit" disabled={isSubmitting || createMutation.isPending}>
          {createMutation.isPending ? 'Saving…' : 'Save policy'}
        </button>
      </div>
    </form>
  )
}

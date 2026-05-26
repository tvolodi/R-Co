-- 034_adp07_agent_role_reserved_usernames.sql
-- ADP-07: Add AGENT_RUNNER as a grantable system role.
-- Reserved username enforcement is handled in backend service policy.

INSERT INTO roles (name, description, is_system)
VALUES ('AGENT_RUNNER', 'Agent execution account role for pipeline/runtime automation', true)
ON CONFLICT (name) DO NOTHING;

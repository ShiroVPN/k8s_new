INSERT INTO api_tokens (name, token, enabled, created_at, scope, expires_at)
VALUES (
    'shiro',
    encode(sha256(convert_to(:'token', 'UTF8')), 'hex'),
    true,
    extract(epoch from now())::bigint,
    'admin',
    0
)
ON CONFLICT (name) DO UPDATE
SET token = EXCLUDED.token,
    enabled = true,
    scope = EXCLUDED.scope,
    expires_at = 0;

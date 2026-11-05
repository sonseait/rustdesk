-- NULL explicitly means that a token does not expire. Usage limits and
-- revocation still apply to these tokens.
ALTER TABLE enrollment_tokens ALTER COLUMN expires_at DROP NOT NULL;

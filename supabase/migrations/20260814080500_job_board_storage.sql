BEGIN;

-- Private bucket for resumes and application attachments. Never public —
-- staff access files exclusively through the edge function, which uses the
-- service role to generate short-lived signed URLs. Anonymous applicants may
-- upload (insert) their own resume at submission time but can never list,
-- read, or overwrite existing objects.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'job-applications',
  'job-applications',
  false,
  10485760, -- 10 MB
  ARRAY['application/pdf', 'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document']
)
ON CONFLICT (id) DO UPDATE SET
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS job_applications_bucket_anon_upload ON storage.objects;
CREATE POLICY job_applications_bucket_anon_upload ON storage.objects
  FOR INSERT TO anon, authenticated
  WITH CHECK (bucket_id = 'job-applications');

-- No SELECT/UPDATE/DELETE policy for anon/authenticated is created on purpose:
-- with RLS enabled and no matching policy, those operations are denied for
-- everyone except service_role (which bypasses RLS). Staff download resumes
-- via signed URLs minted server-side by the edge function.

COMMIT;

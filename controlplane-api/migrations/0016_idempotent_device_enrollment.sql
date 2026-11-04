ALTER TABLE devices ADD COLUMN enrollment_request_id UUID;
CREATE UNIQUE INDEX devices_enrollment_request_id_idx
    ON devices (enrollment_request_id) WHERE enrollment_request_id IS NOT NULL;
ALTER TABLE devices ADD COLUMN enrollment_request_binding TEXT;
ALTER TABLE devices ADD CONSTRAINT devices_enrollment_request_binding_pair
    CHECK ((enrollment_request_id IS NULL) = (enrollment_request_binding IS NULL));

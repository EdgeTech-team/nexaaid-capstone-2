-- tests/sql/baseline_e837b545b195.sql
--
-- The database schema BEFORE the first Alembic migration (revision
-- e837b545b195 "baseline existing schema tracking", which is empty because
-- Neon already had these tables). Used only by
-- tests/test_models_match_migrations.py: it loads this file into a
-- temporary local Postgres, runs every migration to head, and checks the
-- result against the SQLAlchemy models.
--
-- FROZEN: never edit this file to make a test pass. Schema changes go in a
-- new migration. This file only describes the past.
--
-- Reconstructed on 2026-10-03 (no dump of Neon's original schema was ever
-- committed) from:
--   - the models on develop at cb78fa0, minus what later migrations add:
--     the uploads table (543599c29c03), disaster_reports.validated_by and
--     rejection_reason (7ebb7eafb3fe), notifications.entity_type and
--     entity_id (cf61755c6f8a), users.employee_id and must_change_password
--     (da126cd397f0)
--   - 142a5db2006c's downgrade: users.contact_number VARCHAR(20), the
--     idx_* indexes and default-named foreign keys it drops, their
--     ON DELETE rules, and the old check name organizations_status_check
--   - notifications (no model on develop yet): columns from
--     models/notification.py on feat/notification-alerts
-- Limitation: for tables that no migration ever touched, this copies the
-- models, so it cannot catch a mistake that was already in the model on
-- 2026-10-03. It does catch every column a migration adds, renames or
-- creates afterwards (e.g. the uploads.owner_user_id bug fixed in #19).

CREATE TABLE cities (
	city_id SERIAL NOT NULL, 
	city_name VARCHAR(100) NOT NULL, 
	province VARCHAR(100) DEFAULT 'Cebu' NOT NULL, 
	PRIMARY KEY (city_id), 
	UNIQUE (city_name)
);

CREATE TABLE disaster_types (
	disaster_type_id SERIAL NOT NULL, 
	type_name VARCHAR(100) NOT NULL, 
	description TEXT, 
	PRIMARY KEY (disaster_type_id), 
	UNIQUE (type_name)
);

CREATE TABLE guest_donors (
	guest_donor_id SERIAL NOT NULL, 
	full_name VARCHAR(150) NOT NULL, 
	contact_number VARCHAR(20) NOT NULL, 
	email VARCHAR(150), 
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL, 
	PRIMARY KEY (guest_donor_id)
);

CREATE TABLE items (
	item_id SERIAL NOT NULL, 
	item_name VARCHAR(150) NOT NULL, 
	category VARCHAR(100) NOT NULL, 
	unit_of_measure VARCHAR(50) NOT NULL, 
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL, 
	PRIMARY KEY (item_id), 
	UNIQUE (item_name)
);

CREATE TABLE organizations (
	organization_id SERIAL NOT NULL, 
	org_name VARCHAR(150) NOT NULL, 
	organization_type VARCHAR(100) NOT NULL, 
	address TEXT NOT NULL, 
	contact_person VARCHAR(150) NOT NULL, 
	registration_no VARCHAR(100) NOT NULL, 
	contact_email VARCHAR(150) NOT NULL, 
	legitimacy_document_url TEXT, 
	status VARCHAR(20) DEFAULT 'Pending' NOT NULL, 
	approved_by_user_id INTEGER, 
	approved_at TIMESTAMP WITH TIME ZONE, 
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL, 
	PRIMARY KEY (organization_id), 
	CONSTRAINT organizations_status_check CHECK (status IN ('Pending','Approved','Rejected')), 
	UNIQUE (registration_no)
);

CREATE TABLE roles (
	role_id SERIAL NOT NULL, 
	role_name VARCHAR(100) NOT NULL, 
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL, 
	PRIMARY KEY (role_id), 
	UNIQUE (role_name)
);

CREATE TABLE users (
	user_id SERIAL NOT NULL, 
	first_name VARCHAR(50) NOT NULL, 
	last_name VARCHAR(50) NOT NULL, 
	contact_number VARCHAR(20) NOT NULL, 
	email VARCHAR(150) NOT NULL, 
	password_hash VARCHAR(255) NOT NULL, 
	role_id INTEGER NOT NULL, 
	organization_id INTEGER, 
	assigned_barangay_id INTEGER, 
	id_document_url TEXT, 
	is_active BOOLEAN DEFAULT 'true' NOT NULL, 
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL, 
	PRIMARY KEY (user_id), 
	UNIQUE (email)
);

CREATE INDEX idx_users_assigned_barangay ON users (assigned_barangay_id);

CREATE INDEX idx_users_organization ON users (organization_id);

CREATE INDEX idx_users_role ON users (role_id);

CREATE TABLE audit_logs (
	log_id SERIAL NOT NULL, 
	user_id INTEGER NOT NULL, 
	action TEXT NOT NULL, 
	entity_type VARCHAR(100) NOT NULL, 
	entity_id INTEGER, 
	old_value JSONB, 
	new_value JSONB, 
	ip_address VARCHAR(45), 
	timestamp TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL, 
	PRIMARY KEY (log_id)
);

CREATE TABLE barangays (
	barangay_id SERIAL NOT NULL, 
	barangay_name VARCHAR(150) NOT NULL, 
	city_id INTEGER NOT NULL, 
	PRIMARY KEY (barangay_id), 
	UNIQUE (barangay_name)
);

CREATE INDEX idx_barangays_city ON barangays (city_id);

CREATE TABLE notifications (
	notification_id SERIAL NOT NULL, 
	user_id INTEGER NOT NULL, 
	type VARCHAR(100) NOT NULL, 
	title VARCHAR(200) NOT NULL, 
	message TEXT NOT NULL, 
	is_read BOOLEAN DEFAULT 'false' NOT NULL, 
	sent_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL, 
	PRIMARY KEY (notification_id)
);

CREATE TABLE sitios (
	sitio_id SERIAL NOT NULL, 
	barangay_id INTEGER NOT NULL, 
	sitio_name VARCHAR(150) NOT NULL, 
	PRIMARY KEY (sitio_id)
);

CREATE TABLE disaster_reports (
	report_id SERIAL NOT NULL, 
	user_id INTEGER NOT NULL, 
	disaster_type_id INTEGER NOT NULL, 
	barangay_id INTEGER NOT NULL, 
	sitio_id INTEGER, 
	description TEXT, 
	affected_families INTEGER, 
	assistance_needed TEXT, 
	estimated_quantity INTEGER, 
	source VARCHAR(20) NOT NULL, 
	ai_priority_score NUMERIC(5, 2), 
	ai_recommendation TEXT, 
	priority_level VARCHAR(50), 
	status VARCHAR(50) DEFAULT 'Pending' NOT NULL, 
	ai_processed_at TIMESTAMP WITH TIME ZONE, 
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL, 
	updated_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL, 
	PRIMARY KEY (report_id), 
	CONSTRAINT disaster_reports_source_check CHECK (source IN ('Web','Mobile','SMS'))
);

CREATE INDEX idx_disaster_reports_barangay ON disaster_reports (barangay_id);

CREATE INDEX idx_disaster_reports_priority ON disaster_reports (priority_level);

CREATE INDEX idx_disaster_reports_source ON disaster_reports (source);

CREATE INDEX idx_disaster_reports_status ON disaster_reports (status);

CREATE TABLE deliveries (
	delivery_id SERIAL NOT NULL, 
	report_id INTEGER NOT NULL, 
	destination_barangay_id INTEGER NOT NULL, 
	destination_sitio_id INTEGER, 
	handled_by_user_id INTEGER NOT NULL, 
	status VARCHAR(50) NOT NULL, 
	delivery_date TIMESTAMP WITH TIME ZONE NOT NULL, 
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL, 
	PRIMARY KEY (delivery_id), 
	CONSTRAINT deliveries_status_check CHECK (status IN ('Preparing','In Transit','Delivered', 'Confirmed'))
);

CREATE TABLE inventory (
	inventory_id SERIAL NOT NULL, 
	item_id INTEGER NOT NULL, 
	report_id INTEGER NOT NULL, 
	quantity INTEGER NOT NULL, 
	last_updated TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL, 
	PRIMARY KEY (inventory_id), 
	CONSTRAINT uq_inventory_item_report UNIQUE (item_id, report_id)
);

CREATE TABLE physical_donations (
	donation_id SERIAL NOT NULL, 
	user_id INTEGER, 
	guest_donor_id INTEGER, 
	report_id INTEGER NOT NULL, 
	item_id INTEGER NOT NULL, 
	packaging VARCHAR(100) NOT NULL, 
	quantity INTEGER NOT NULL, 
	estimated_value NUMERIC(10, 2), 
	handover_method VARCHAR(20) NOT NULL, 
	pickup_address TEXT, 
	qr_reference VARCHAR(100) NOT NULL, 
	status VARCHAR(50) DEFAULT 'Pending' NOT NULL, 
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL, 
	PRIMARY KEY (donation_id), 
	CONSTRAINT physical_donations_quantity_check CHECK (quantity > 0), 
	CONSTRAINT chk_donation_donor_source CHECK ((user_id IS NOT NULL AND guest_donor_id IS NULL) OR (user_id IS NULL AND guest_donor_id IS NOT NULL)), 
	CONSTRAINT physical_donations_handover_method_check CHECK (handover_method IN ('Drop Off', 'Door to Door')), 
	CONSTRAINT chk_physical_donations_status CHECK (status IN ('Pending', 'Received', 'Confirmed')), 
	UNIQUE (qr_reference)
);

CREATE INDEX idx_physical_donations_guest ON physical_donations (guest_donor_id);

CREATE INDEX idx_physical_donations_report ON physical_donations (report_id);

CREATE INDEX idx_physical_donations_report_status ON physical_donations (report_id, status);

CREATE INDEX idx_physical_donations_status ON physical_donations (status);

CREATE INDEX idx_physical_donations_user ON physical_donations (user_id);

CREATE TABLE report_fulfillments (
	fulfillment_id SERIAL NOT NULL, 
	report_id INTEGER NOT NULL, 
	total_items_needed INTEGER NOT NULL, 
	total_items_delivered INTEGER DEFAULT '0' NOT NULL, 
	fulfillment_percentage NUMERIC(5, 2) DEFAULT '0.00' NOT NULL, 
	verification_status VARCHAR(20) DEFAULT 'Not Started' NOT NULL, 
	verified_by_user_id INTEGER, 
	verified_at TIMESTAMP WITH TIME ZONE, 
	PRIMARY KEY (fulfillment_id), 
	CONSTRAINT chk_report_fulfillments_status CHECK (verification_status IN ('Not Started', 'Partial', 'Complete')), 
	UNIQUE (report_id)
);

CREATE TABLE sms_report_metadata (
	sms_meta_id SERIAL NOT NULL, 
	report_id INTEGER NOT NULL, 
	contact_number VARCHAR(20) NOT NULL, 
	raw_message TEXT NOT NULL, 
	encoded_by_user_id INTEGER NOT NULL, 
	encoded_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL, 
	PRIMARY KEY (sms_meta_id), 
	UNIQUE (report_id)
);

CREATE TABLE delivery_items (
	delivery_item_id SERIAL NOT NULL, 
	delivery_id INTEGER NOT NULL, 
	item_id INTEGER NOT NULL, 
	quantity INTEGER NOT NULL, 
	PRIMARY KEY (delivery_item_id), 
	CONSTRAINT delivery_items_quantity_check CHECK (quantity > 0)
);

CREATE TABLE donation_confirmations (
	confirmation_id SERIAL NOT NULL, 
	donation_id INTEGER NOT NULL, 
	confirmed_by_user_id INTEGER NOT NULL, 
	status VARCHAR(20) NOT NULL, 
	notes VARCHAR(200), 
	confirmed_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL, 
	PRIMARY KEY (confirmation_id)
);

CREATE TABLE logistics_requests (
	request_id SERIAL NOT NULL, 
	delivery_id INTEGER NOT NULL, 
	requested_by_user_id INTEGER NOT NULL, 
	assigned_to_user_id INTEGER, 
	status VARCHAR(30) DEFAULT 'Pending' NOT NULL, 
	scheduled_date TIMESTAMP WITH TIME ZONE, 
	notes TEXT, 
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL, 
	PRIMARY KEY (request_id)
);

CREATE TABLE receipts (
	receipt_id SERIAL NOT NULL, 
	delivery_id INTEGER NOT NULL, 
	received_by_user_id INTEGER NOT NULL, 
	received_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL, 
	remarks TEXT, 
	PRIMARY KEY (receipt_id), 
	UNIQUE (delivery_id)
);

CREATE TABLE received_goods (
	receive_id SERIAL NOT NULL, 
	donation_id INTEGER NOT NULL, 
	actual_quantity INTEGER NOT NULL, 
	received_by_user_id INTEGER NOT NULL, 
	received_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL, 
	notes TEXT, 
	PRIMARY KEY (receive_id), 
	CONSTRAINT received_goods_actual_quantity_check CHECK (actual_quantity > 0)
);

ALTER TABLE organizations ADD CONSTRAINT fk_org_approved_by FOREIGN KEY(approved_by_user_id) REFERENCES users (user_id) ON DELETE SET NULL;

ALTER TABLE users ADD FOREIGN KEY(assigned_barangay_id) REFERENCES barangays (barangay_id) ON DELETE SET NULL;

ALTER TABLE users ADD FOREIGN KEY(organization_id) REFERENCES organizations (organization_id) ON DELETE SET NULL;

ALTER TABLE users ADD FOREIGN KEY(role_id) REFERENCES roles (role_id) ON DELETE RESTRICT;

ALTER TABLE audit_logs ADD FOREIGN KEY(user_id) REFERENCES users (user_id);

ALTER TABLE barangays ADD FOREIGN KEY(city_id) REFERENCES cities (city_id) ON DELETE RESTRICT;

ALTER TABLE notifications ADD FOREIGN KEY(user_id) REFERENCES users (user_id);

ALTER TABLE sitios ADD FOREIGN KEY(barangay_id) REFERENCES barangays (barangay_id) ON DELETE RESTRICT;

ALTER TABLE disaster_reports ADD FOREIGN KEY(barangay_id) REFERENCES barangays (barangay_id) ON DELETE RESTRICT;

ALTER TABLE disaster_reports ADD FOREIGN KEY(disaster_type_id) REFERENCES disaster_types (disaster_type_id) ON DELETE RESTRICT;

ALTER TABLE disaster_reports ADD FOREIGN KEY(sitio_id) REFERENCES sitios (sitio_id) ON DELETE SET NULL;

ALTER TABLE disaster_reports ADD FOREIGN KEY(user_id) REFERENCES users (user_id) ON DELETE RESTRICT;

ALTER TABLE deliveries ADD FOREIGN KEY(destination_barangay_id) REFERENCES barangays (barangay_id) ON DELETE RESTRICT;

ALTER TABLE deliveries ADD FOREIGN KEY(destination_sitio_id) REFERENCES sitios (sitio_id) ON DELETE SET NULL;

ALTER TABLE deliveries ADD FOREIGN KEY(handled_by_user_id) REFERENCES users (user_id) ON DELETE RESTRICT;

ALTER TABLE deliveries ADD FOREIGN KEY(report_id) REFERENCES disaster_reports (report_id) ON DELETE RESTRICT;

ALTER TABLE inventory ADD FOREIGN KEY(item_id) REFERENCES items (item_id) ON DELETE RESTRICT;

ALTER TABLE inventory ADD FOREIGN KEY(report_id) REFERENCES disaster_reports (report_id) ON DELETE RESTRICT;

ALTER TABLE physical_donations ADD FOREIGN KEY(guest_donor_id) REFERENCES guest_donors (guest_donor_id) ON DELETE RESTRICT;

ALTER TABLE physical_donations ADD FOREIGN KEY(item_id) REFERENCES items (item_id) ON DELETE RESTRICT;

ALTER TABLE physical_donations ADD FOREIGN KEY(report_id) REFERENCES disaster_reports (report_id) ON DELETE RESTRICT;

ALTER TABLE physical_donations ADD FOREIGN KEY(user_id) REFERENCES users (user_id) ON DELETE RESTRICT;

ALTER TABLE report_fulfillments ADD FOREIGN KEY(report_id) REFERENCES disaster_reports (report_id) ON DELETE CASCADE;

ALTER TABLE report_fulfillments ADD FOREIGN KEY(verified_by_user_id) REFERENCES users (user_id) ON DELETE SET NULL;

ALTER TABLE sms_report_metadata ADD FOREIGN KEY(encoded_by_user_id) REFERENCES users (user_id) ON DELETE RESTRICT;

ALTER TABLE sms_report_metadata ADD FOREIGN KEY(report_id) REFERENCES disaster_reports (report_id) ON DELETE CASCADE;

ALTER TABLE delivery_items ADD FOREIGN KEY(delivery_id) REFERENCES deliveries (delivery_id) ON DELETE CASCADE;

ALTER TABLE delivery_items ADD FOREIGN KEY(item_id) REFERENCES items (item_id) ON DELETE RESTRICT;

ALTER TABLE donation_confirmations ADD FOREIGN KEY(confirmed_by_user_id) REFERENCES users (user_id);

ALTER TABLE donation_confirmations ADD FOREIGN KEY(donation_id) REFERENCES physical_donations (donation_id);

ALTER TABLE logistics_requests ADD FOREIGN KEY(assigned_to_user_id) REFERENCES users (user_id) ON DELETE SET NULL;

ALTER TABLE logistics_requests ADD FOREIGN KEY(delivery_id) REFERENCES deliveries (delivery_id) ON DELETE RESTRICT;

ALTER TABLE logistics_requests ADD FOREIGN KEY(requested_by_user_id) REFERENCES users (user_id) ON DELETE RESTRICT;

ALTER TABLE receipts ADD FOREIGN KEY(delivery_id) REFERENCES deliveries (delivery_id) ON DELETE CASCADE;

ALTER TABLE receipts ADD FOREIGN KEY(received_by_user_id) REFERENCES users (user_id) ON DELETE RESTRICT;

ALTER TABLE received_goods ADD FOREIGN KEY(donation_id) REFERENCES physical_donations (donation_id) ON DELETE RESTRICT;

ALTER TABLE received_goods ADD FOREIGN KEY(received_by_user_id) REFERENCES users (user_id) ON DELETE RESTRICT;

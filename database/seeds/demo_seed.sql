-- NexaAid demo / test data for the Neon database.
-- Safe to run more than once: every insert skips rows that already exist.
-- Run it in the Neon SQL Editor. TEST DATA ONLY - do not run on production.

-- 1. Ten sitios per barangay (Sitio 1 ... Sitio 10) so the report form's
--    sitio dropdown has choices for every barangay.
INSERT INTO sitios (barangay_id, sitio_name)
SELECT b.barangay_id, 'Sitio ' || n
FROM barangays b
CROSS JOIN generate_series(1, 10) AS n
WHERE NOT EXISTS (
    SELECT 1 FROM sitios s
    WHERE s.barangay_id = b.barangay_id AND s.sitio_name = 'Sitio ' || n
);

-- 2. Common relief items with their units, used by the "needs" builder
--    on the report form and by donations / deliveries.
INSERT INTO items (item_name, category, unit_of_measure)
SELECT v.item_name, v.category, v.unit
FROM (VALUES
    ('Rice',            'Food',     'kg'),
    ('Drinking Water',  'Water',    'gallons'),
    ('Canned Goods',    'Food',     'cans'),
    ('Noodles',         'Food',     'packs'),
    ('Hygiene Kit',     'Hygiene',  'kits'),
    ('Blanket',         'Shelter',  'pcs'),
    ('Sleeping Mat',    'Shelter',  'pcs'),
    ('Medicine Kit',    'Medical',  'boxes'),
    ('Clothing',        'Clothing', 'packs')
) AS v(item_name, category, unit)
WHERE NOT EXISTS (SELECT 1 FROM items i WHERE lower(i.item_name) = lower(v.item_name));

-- 2b. Disaster types common in Mandaue City / Cebu (report form dropdown).
INSERT INTO disaster_types (type_name, description)
SELECT v.type_name, v.description
FROM (VALUES
    ('Flood',             'Rising water from heavy rain or overflowing rivers'),
    ('Flash Flood',       'Sudden flooding within hours of heavy rain'),
    ('Typhoon',           'Tropical cyclone with strong winds and heavy rain'),
    ('Storm Surge',       'Coastal flooding pushed in by a typhoon'),
    ('Fire',              'Residential or commercial fire'),
    ('Earthquake',        'Ground shaking and structural damage'),
    ('Landslide',         'Soil or rock sliding down slopes'),
    ('Tsunami',           'Sea waves caused by an undersea earthquake'),
    ('Volcanic Eruption', 'Ashfall or eruption affecting the area'),
    ('Drought',           'Long dry spell affecting water and food supply'),
    ('Disease Outbreak',  'Epidemic needing medical and hygiene supplies')
) AS v(type_name, description)
WHERE NOT EXISTS (SELECT 1 FROM disaster_types d WHERE lower(d.type_name) = lower(v.type_name));

-- 2c. audit_logs (manuscript data dictionary) for the activity logs on the
--     Administrator and CSWS dashboards. Only created if it is missing.
CREATE TABLE IF NOT EXISTS audit_logs (
    log_id      SERIAL PRIMARY KEY,
    user_id     INTEGER NOT NULL REFERENCES users(user_id),
    action      TEXT NOT NULL,
    entity_type VARCHAR(100) NOT NULL,
    entity_id   INTEGER,
    old_value   JSONB,
    new_value   JSONB,
    ip_address  VARCHAR(45),
    "timestamp" TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 3. One Barangay Receiving Representative per barangay (manuscript UC-B1:
--    each rep only sees aid for the assigned barangay).
--    Email: <barangay name, lowercase, no spaces>.rep@example.com
--    Password: the same as csws.test@example.com (testpass123).
INSERT INTO users (first_name, last_name, email, password_hash, contact_number,
                   role_id, assigned_barangay_id, is_active)
SELECT 'Brgy ' || b.barangay_name,
       'Receiving Rep',
       regexp_replace(lower(b.barangay_name), '[^a-z0-9]', '', 'g') || '.rep@example.com',
       (SELECT password_hash FROM users WHERE email = 'csws.test@example.com'),
       '09170000000',
       (SELECT role_id FROM roles WHERE role_name = 'Barangay Receiving Representative'),
       b.barangay_id,
       true
FROM barangays b
ON CONFLICT (email) DO NOTHING;

-- The existing test rep must also have a barangay, or the app blocks it.
UPDATE users
SET assigned_barangay_id = (SELECT MIN(barangay_id) FROM barangays)
WHERE email = 'ana.test@example.com' AND assigned_barangay_id IS NULL;

-- Relief organizations must be Approved by the Administrator to log in
-- (manuscript UC-A2). Approve the existing test organization.
UPDATE organizations SET status = 'Approved', approved_at = NOW()
WHERE status <> 'Approved' AND organization_id IN (
    SELECT organization_id FROM users WHERE email = 'maria.santos@helpinghands.org');

-- 4. Give the donor and relief organization test accounts the same test
--    password (testpass123) so they can log in from the demo chips.
UPDATE users
SET password_hash = (SELECT password_hash FROM users WHERE email = 'csws.test@example.com')
WHERE email IN ('halberz43@gmail.com', 'maria.santos@helpinghands.org');

-- Check the results:
SELECT u.email, r.role_name, b.barangay_name
FROM users u
JOIN roles r ON r.role_id = u.role_id
LEFT JOIN barangays b ON b.barangay_id = u.assigned_barangay_id
ORDER BY r.role_id, u.email;

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
    ('Rice',             'Food',     'kg'),
    ('Drinking Water',   'Water',    'L'),
    ('Canned Goods',     'Food',     'cans'),
    ('Noodles',          'Food',     'packs'),
    ('Hygiene Kit',      'Hygiene',  'kits'),
    ('Blanket',          'Shelter',  'pcs'),
    ('Sleeping Mat',     'Shelter',  'pcs'),
    ('Medicine Kit',     'Medical',  'boxes'),
    -- NF-006: clothing is counted in pieces (migration b5e1f7a3c8d2).
    -- Municipal Water and Clothing (packs) are no longer in the catalog.
    ('Clothing – Upper', 'Clothing', 'pcs'),
    ('Clothing – Lower', 'Clothing', 'pcs')
) AS v(item_name, category, unit)
WHERE NOT EXISTS (SELECT 1 FROM items i WHERE lower(i.item_name) = lower(v.item_name));

-- 2a. Base units and common sizes (per-item fulfillment, Oct 2026).
--     Needs MIGRATION 9b3f7c1d2e48 first (alembic upgrade head).
--     Every quantity of an item is a whole number in its unit_of_measure
--     (its BASE UNIT): kg = weight, L = volume, anything else is counted.
--     Sizes are what one piece holds, in that base unit. A donor picks one
--     and the app works out packs x per pack x size (e.g. 3 boxes x 16 x
--     1.5 L = 72 L). This list is maintained by the developers: add a row
--     here and re-run this file to offer a new size.
INSERT INTO item_sizes (item_id, label, amount, sort_order)
SELECT i.item_id, v.label, v.amount, v.sort_order
FROM (VALUES
    ('Rice',           '1 kg pack',              1,        1),
    ('Rice',           '2 kg pack',              2,        2),
    ('Rice',           '5 kg pack',              5,        3),
    ('Rice',           '10 kg sack',             10,       4),
    ('Rice',           '25 kg sack',             25,       5),
    ('Rice',           '50 kg sack',             50,       6),
    ('Drinking Water', '330 ml bottle',          0.33,     1),
    ('Drinking Water', '350 ml bottle',          0.35,     2),
    ('Drinking Water', '500 ml bottle',          0.5,      3),
    ('Drinking Water', '1 L bottle',             1,        4),
    ('Drinking Water', '1.5 L bottle',           1.5,      5),
    ('Drinking Water', '2 L bottle',             2,        6),
    ('Drinking Water', '1 gallon container',     3.7854,   7),
    ('Drinking Water', '5 gallon container',     18.9271,  8)
) AS v(item_name, label, amount, sort_order)
JOIN items i ON lower(i.item_name) = lower(v.item_name) AND i.active
WHERE NOT EXISTS (
    SELECT 1 FROM item_sizes s WHERE s.item_id = i.item_id AND s.label = v.label
);

-- 2b. Disaster types for Mandaue City (report form dropdown). Same list as
--     migrations d3f8b2a61c47 and f6a2d9c4b8e1 (no Volcanic Eruption); an
--     existing type keeps its id and gets the current description.
INSERT INTO disaster_types (type_name, description)
VALUES
    ('Typhoon',          'Tropical cyclone with strong winds and heavy rain'),
    ('Flood',            'Rising water from heavy rain or overflowing rivers'),
    ('Flash Flood',      'Sudden flooding within hours of heavy rain'),
    ('Storm Surge',      'Coastal flooding caused by a typhoon''s storm surge'),
    ('Earthquake',       'Ground shaking from a seismic event, including damage from aftershocks'),
    ('Fire',             'Residential, commercial, or industrial fire'),
    ('Landslide',        'Soil or rock sliding down slopes'),
    ('Tsunami',          'Coastal flooding caused by a seismic event'),
    ('Drought',          'Long dry spell affecting water and food supply'),
    ('Disease Outbreak', 'Epidemic needing medical and hygiene supplies'),
    ('Other',            'Disaster not covered by the listed types; details go in the report description')
ON CONFLICT (type_name) DO UPDATE SET description = EXCLUDED.description;

-- 2b-1. NF-004: hazard-prone barangays. Same lists as migrations
--       a4d8c2e6f1b9 and d9e3b7a1c5f2. Barangays missing from this
--       database are skipped. Re-running sets the source of an existing
--       pair to the text below.
UPDATE disaster_types SET is_location_specific = true
WHERE type_name IN ('Landslide', 'Storm Surge', 'Tsunami');

INSERT INTO barangay_hazards (barangay_id, disaster_type_id, source)
SELECT b.barangay_id, t.disaster_type_id, v.source
FROM (VALUES
    -- Confirmed
    ('Landslide',   'Casili',     'Mandaue CDRRMO public statements / city barangay map'),
    ('Landslide',   'Tawason',    'Mandaue CDRRMO public statements / city barangay map'),
    ('Landslide',   'Cubacub',    'Mandaue CDRRMO public statements / city barangay map'),
    ('Landslide',   'Tingub',     'Mandaue CDRRMO public statements / city barangay map'),
    ('Storm Surge', 'Paknaan',    'Mandaue CDRRMO public statements / city barangay map'),
    ('Storm Surge', 'Umapad',     'Mandaue CDRRMO public statements / city barangay map'),
    ('Storm Surge', 'Opao',       'Mandaue CDRRMO public statements / city barangay map'),
    ('Storm Surge', 'Looc',       'Mandaue CDRRMO public statements / city barangay map'),
    ('Tsunami',     'Paknaan',    'Mandaue CDRRMO public statements / city barangay map'),
    ('Tsunami',     'Umapad',     'Mandaue CDRRMO public statements / city barangay map'),
    ('Tsunami',     'Opao',       'Mandaue CDRRMO public statements / city barangay map'),
    ('Tsunami',     'Looc',       'Mandaue CDRRMO public statements / city barangay map'),
    -- PENDING CDRRMO confirmation
    ('Storm Surge', 'Subangdaku', 'PENDING CDRRMO confirmation'),
    ('Storm Surge', 'Tipolo',     'PENDING CDRRMO confirmation'),
    ('Storm Surge', 'Centro',     'PENDING CDRRMO confirmation'),
    ('Storm Surge', 'Labogon',    'PENDING CDRRMO confirmation'),
    ('Tsunami',     'Subangdaku', 'PENDING CDRRMO confirmation'),
    ('Tsunami',     'Tipolo',     'PENDING CDRRMO confirmation'),
    ('Tsunami',     'Centro',     'PENDING CDRRMO confirmation'),
    ('Tsunami',     'Labogon',    'PENDING CDRRMO confirmation')
) AS v(type_name, barangay_name, source)
JOIN disaster_types t ON t.type_name = v.type_name
JOIN barangays b ON b.barangay_name = v.barangay_name
ON CONFLICT (barangay_id, disaster_type_id) DO UPDATE SET source = EXCLUDED.source;



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

-- 5. A second Administrator account for the CSWS Head Office (Nov 4).
--    Login: headoffice@gmail.com   Password: testpass123 (same hash as
--    csws.test@example.com). Skipped if the email already exists.
INSERT INTO users (first_name, last_name, email, password_hash, contact_number,
                   role_id, is_active, must_change_password)
SELECT 'Head',
       'Office',
       'headoffice@gmail.com',
       (SELECT password_hash FROM users WHERE email = 'csws.test@example.com'),
       '09170000000',
       (SELECT role_id FROM roles
        WHERE lower(role_name) IN ('administrator', 'admin')
        ORDER BY role_id LIMIT 1),
       true,
       false
ON CONFLICT (email) DO NOTHING;

-- Check the results:
SELECT u.email, r.role_name, b.barangay_name
FROM users u
JOIN roles r ON r.role_id = u.role_id
LEFT JOIN barangays b ON b.barangay_id = u.assigned_barangay_id
ORDER BY r.role_id, u.email;

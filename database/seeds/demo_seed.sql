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
INSERT INTO items (item_name, category, unit_of_measure) VALUES
    ('Rice',            'Food',     'kg'),
    ('Drinking Water',  'Water',    'gallons'),
    ('Canned Goods',    'Food',     'cans'),
    ('Noodles',         'Food',     'packs'),
    ('Hygiene Kit',     'Hygiene',  'kits'),
    ('Blanket',         'Shelter',  'pcs'),
    ('Sleeping Mat',    'Shelter',  'pcs'),
    ('Medicine Kit',    'Medical',  'boxes'),
    ('Clothing',        'Clothing', 'packs')
ON CONFLICT (item_name) DO NOTHING;

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

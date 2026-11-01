# Per-item fulfillment, base units and priority (Oct 2026)

Owner: Castillo (Module 3, fulfillment). Branch `castillo/oct19-all-fixes`, migrations `9b3f7c1d2e48` (per-item) and `3e8a6f2c9d15` (account delete).

## Why

Before this change, a report's needs were one total. "Rice: 500 kg, Water: 200 gal" was saved as `estimated_quantity = 700`, and every delivered item counted against it. 700 bottles of anything marked the report 100% fulfilled, even with no rice delivered. Sacks, kilos and gallons were also mixed in the same numbers (testing items 2.5 and 4.1).

## The rules (team decisions)

1. **Every item has one base unit**: `items.unit_of_measure`. Rice = kg, Drinking Water = **L**, and everything else is counted (pcs, cans, kits…). Every quantity of an item in the system is a whole number in that unit: needs, donations, received goods, inventory and deliveries.
2. **Packaging is only a description.** A donor describes a line as **packs × per pack × size**, and the server works out the total:
   - 3 boxes × 16 × 1.5 L bottle = **72 L**
   - 4 × 25 kg sack = **100 kg**
   - 10 packs × 6 cans = **60 cans**

   Totals are rounded to a whole base unit (3 × 500 ml = 1.5 L → 2 L). The exact breakdown is kept on the donation.
3. **Needs are per item** (`report_needs`). Each need is measured on its own and **capped at 100%**. The report's percentage is the **average** of its needs (equal weight per need).
4. **Three meters per need.** **Delivered** (barangay receipt) is the official fulfillment % and the one priority uses.

   | Meter | Counts |
   |---|---|
   | pledged | donations not expired or cancelled (the counted amount once CSWS received it) |
   | confirmed | received by CSWS **and** acknowledged by the CMO ("in stock"; stays counted after delivery) |
   | delivered | deliveries the barangay confirmed receiving |
5. **Goods that match no need** are listed as `additional_goods` and never raise the %.
6. **Item list and sizes are fixed by the developers** in `database/seeds/demo_seed.sql`. There is no admin screen.
7. **Priority, option C: how severe × how much is still missing.**
   - *Severity* = affected families and disaster type, in a 4 : 3 ratio (40 : 30). Estimated quantity is **no longer scored**, because it's a sum of different units.
   - *Missing* = 100 − the report's delivered %. It scales the severity from 100% (nothing delivered) down to 40% (almost everything delivered). 100% delivered is always **Low**.
   - Example, 120 families + flood: 0% delivered → Critical, 30% → High, 50% → High, 70% → Medium, 90% → Medium, 100% → Low. The real % is used, so "Partial" no longer counts as a flat 50 (testing #2), and the level steps down gradually instead of jumping from High to Low (#3).
8. **Priority is never set by hand** (testing #5). The manuscript (Table 32) says the computation is "automated but non-autonomous": people decide the actual relief allocation, and the label is guidance. `PATCH /reports/{id}` with `priority_level`, `ai_priority_score` or `ai_recommendation` returns 422.

## Older apps keep working

Nothing on the current screens breaks:

| Old client sends | Server does |
|---|---|
| report with `estimated_quantity`, no `needs` | one **"General needs"** line with that total. It counts every item, so the % works exactly like before. |
| donation line with `quantity` + `packaging` | saved as-is (the quantity is already in the item's unit, as the donate form shows) |
| receive with `actual_quantity` | unchanged |
| delivery items with `quantity` | unchanged |

Existing reports in Neon each got one "General needs" line from their old `estimated_quantity`, so their percentage didn't change.

**Drinking Water**: if water was already used, the old item is kept as "Drinking Water (gallons, old)", hidden from dropdowns so old records stay correct, and a new "Drinking Water" in **L** is added. Pick the new one from now on.

## API changes (all additive)

### `GET /lookups`, `items`
Only active items are listed. Each item now has:
```json
{"id": 2, "item_name": "Drinking Water", "unit": "L", "kind": "volume",
 "size_units": ["L", "ml", "gallon"],
 "sizes": [{"id": 3, "label": "500 ml bottle", "amount": 0.5}, {"id": 5, "label": "1.5 L bottle", "amount": 1.5}]}
```
`kind` is `weight` / `volume` / `count`. `size_units` are the units a custom size may be typed in.
`validated_reports[*].needs` and `GET /public/reports[*].needs` contain the per-need meters (see below).

### Reports: `POST /reports/`, `PUT /reports/{id}/mine`, `POST /reports/sms`, `PATCH /reports/{id}`
New optional field:
```json
"needs": [
  {"item_id": 1, "quantity": 500},
  {"item_id": 2, "quantity": 200},
  {"other_item_name": "Diapers", "other_item_unit": "pcs", "quantity": 100}
]
```
- When `needs` is sent, the server sets `estimated_quantity` = their sum (for older screens) and, if `assistance_needed` is empty, fills it with "Rice: 500 kg, Drinking Water: 200 L, Diapers: 100 pcs".
- The same item twice → 422. A retired item → 422.
- Responses now include `"needs": [{"need_id", "item_id", "item_name", "unit", "quantity"}]`. `item_id: null` = "General needs".
- `PATCH` by the admin after validation: changing `needs` or `affected_families` recalculates fulfillment **and** priority straight away. Priority fields can't be sent (422).

### `GET /reports/{id}/needs` (new)
Public for validated reports. Otherwise the reporter, staff and barangay officials can see it.
```json
{"report_id": 7, "fulfillment_percentage": 21.5, "pledged_percentage": 33.4, "confirmed_percentage": 33.4,
 "needs": [{"need_id": 1, "item_id": 1, "item_name": "Rice", "unit": "kg", "needed": 500,
            "pledged": 150, "confirmed": 150, "delivered": 150,
            "pledged_percentage": 30.0, "confirmed_percentage": 30.0, "delivered_percentage": 30.0}],
 "additional_goods": [{"item_id": 9, "item_name": "Blanket", "unit": "pcs", "pledged": 5, "confirmed": 0, "delivered": 0}]}
```

### Donations: `POST /donations/batch`, `POST /donations/`, `PUT /donations/entries/{ref}`
Each line may now send the breakdown **instead of** `quantity` + `packaging`:
```json
{"item_id": 2, "pack_count": 3, "per_pack": 16, "size_id": 5}
{"item_id": 2, "pack_count": 3, "per_pack": 16, "size_amount": 1.5, "size_unit": "L"}
{"item_id": 7, "pack_count": 10, "per_pack": 6}
```
- `per_pack` defaults to 1. No size = 1 base unit each.
- `size_unit` must fit the item: kg/g for weight; L/ml/gallon for volume; the item's own unit for counted items.
- A total under 1 base unit → 422.
- `packaging` is optional with a breakdown; the server writes e.g. "Pack of 16 x 1.5 L".
- Entry views (`items[*]`) now include `pack_count`, `per_pack`, `size_amount`, `size_label` and `amount_text` ("3 x 16 x 1.5 L bottle = 72 L").

### Receiving: `POST /donations/receive`, `POST /donations/entries/{ref}/receive`
- `actual_quantity` is in the item's base unit (as before).
- New optional `item_id` per line: **what the goods really are**. Use it when a donor typed "Bigas" or picked the wrong item. It's logged as `RECLASSIFY DONATION`.

## Screen changes for each teammate (do when ready; nothing breaks before)

| Who | Screen | Change |
|---|---|---|
| **Mariquit** | Report form (2.1) | Send `needs` (item + quantity in the item's unit from `/lookups`) instead of the text summary + total. "Other" sends `other_item_name` + `other_item_unit`. |
| **Mariquit** | Report detail (2.4 / 2.5) | Show `GET /reports/{id}/needs`: one bar per need (delivered %), with pledged / confirmed as lighter bars. |
| **Mariquit** | Receiving (Module 5) | Pre-fill `actual_quantity` from the donation's `quantity` (already base units). Show `amount_text`. Optional item picker → `item_id`. |
| **Hoyohoy** | Donate form (4.1, 4.2) | Item → size (chips from `sizes`, plus "Custom": amount + unit from `size_units`) → per pack (Single / 6 / 10 / 12 / 15 / 16 / 24 / custom) → number of packs. Show "You're donating 72 L" before submit. Send the breakdown fields, not `quantity`. Remove "Sack" as a unit (item 4.1). Donor cards: show which needs are still open from `validated_reports[*].needs`. |
| **Fernandez** | Deliveries (8.x) | Quantities stay in base units. Show the unit next to every number. |
| **Fernandez** | Dashboards (9.x) | Per-item progress bars from `GET /reports/{id}/needs` where a report is shown. |

Until each screen is updated, the old behaviour continues. Reports sent the old way get a "General needs" line, so their % works like before but isn't per item.

**Already done (Oct 20, Castillo):**
- **Report form** (`report_screens.dart`): sends `needs` (item + quantity, or "Other" name + unit) on submit, edit and Encode SMS. Editing a report opens from its saved needs.
- **Donate form** (`donate_screen.dart`): item → size of each (chips from `sizes`, or "Other size" = amount + unit) → items per pack (Single / 6 / 10 / 12 / 15 / 16 / 24 / Other) → how many. It shows "You're donating 72 L" with the breakdown, and sends the breakdown fields instead of `quantity` + `packaging`. The fixed packaging list (with "Sack") is gone. Counted items (cans, kits, pcs) have no size. The report card at the top shows what is still needed per item, and each item says whether the report asked for it.
- **Receiving** (`batch_sheet.dart`): "Declared" shows the donor's breakdown ("3 x 16 x 1.5 L bottle = 72 L"). **Wrong item?** lets CSWS pick what the goods really are, and sends `item_id`. If the unit changes, the amount is cleared so it is entered again in the new unit.
- Tests: `mobile/test/per_item_fulfillment_test.dart`.

## Neon steps (Castillo applies migrations)

1. `alembic upgrade head` (adds the tables and columns, backfills General needs, moves water to L, adds users.deleted_at).
2. Re-run `database/seeds/demo_seed.sql` (safe to re-run; adds the item sizes).
3. `python scripts/recompute_priorities.py` (dry run: lists reports whose level changes under option A), then `--apply --as-user <admin email>`.

## Tests

`backend/app/tests/test_per_item_fulfillment.py` walks the whole chain with real logins (report with needs → validate → donations in packs → receive, including a reclassify → CMO → delivery → barangay receipt → per-item meters and priority), and checks old-style clients and editing needs. The migration was checked on Postgres: water with existing donations, General needs backfill, re-run, downgrade.

## Also on this branch: account delete and cleanup (Appendix H 1.2, testing feedback)

- **Admin → a deactivated account → "Delete account".** The row is kept, because reports and deliveries point at it, but it's anonymized: name, email, username, phone, address, employee ID and ID photos are removed. The email and username can then register again. The account disappears from every list. "Restore account" (previously "Activate account") brings a deactivated account back.
- **`DELETE /admin/users/{id}`**: only for deactivated accounts (409 otherwise), not for yourself (400), Administrator only.
- **Login tokens** must now match the account's id, so a deleted account's old token can't open a new account that reuses the email (`core/auth.py`).
- **`python scripts/delete_accounts.py --email <address>` or `--match "%@example.com"`**: dry run first, then `--apply --as-user <admin email>`. Use it for the sample accounts that blocked "email already registered". It never deletes Administrators. Read the list before applying a broad pattern: the demo seed's `.rep` / `.test` accounts also end in `@example.com`.

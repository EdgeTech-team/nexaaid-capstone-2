from fastapi import APIRouter, Depends, HTTPException, Query
from core.reference_data.item_quantities import donated_item_fields
from sqlalchemy.orm import Session

from core.shared.database import get_db
from core.m1_user_management.auth import barangay_scope, require_role
from core.m4_donation_management.physical_donation_model import PhysicalDonation
from core.m5_inventory.received_goods_model import ReceivedGoods
from core.m4_donation_management.physical_donation_schema import PhysicalDonationResponse
from core.m1_user_management.user_rbac_model import User
from core.m5_inventory.inventory_model import Inventory
from core.m5_inventory.received_goods_schema import ReceivedGoodsCreate, ReceivedGoodsResponse
from core.notifications.notifications import notify, notify_many, user_ids_with_role
from core.m5_inventory.inventory import add_received_stock
from core.m5_inventory.delivery_allocation import add_receipts
from core.m4_donation_management.donation_entries import ENTRY_SORTS, build_entries, filter_and_sort, group_by_report
from core.m4_donation_management.donation_expiry import CLOSED, close_rows, expire_overdue, nice_date


from typing import Optional
from pydantic import ConfigDict
from pydantic import BaseModel, Field
from core.reference_data.item_model import Item
from datetime import datetime
from core.shared.audit import log_action
from core.m4_donation_management.guest_donor_model import GuestDonor
from core.m2_disaster_reporting.report_model import DisasterReport, DisasterType, Barangay

router = APIRouter(prefix="/donations", tags=["CSWS Receiving"])

# Daniel (Oct 10): tell the donor what happens next, in order.
RECEIVED_BODY = ("CSWS received your donation and is checking it. "
                 "Next, the CMO acknowledges it.")


@router.get("/pending")
def list_pending_donations(
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("CSWS Main Office", "Administrator")),
):
    expire_overdue(db)
    return db.query(PhysicalDonation).filter(PhysicalDonation.status == "Pending").all()


class InventoryResponse(BaseModel):
    inventory_id: int
    item_id: int
    item_name: str
    unit: Optional[str] = None
    report_id: int
    report_label: Optional[str] = None
    quantity: int
    last_updated: datetime

    model_config = ConfigDict(from_attributes=True)


@router.get("/inventory", response_model=list[InventoryResponse])
def view_inventory(
    report_id: Optional[int] = None,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("CSWS Main Office", "Administrator")),
):
    # A row whose goods all went out on deliveries stays in the table at 0
    # (it comes back up if a delivery is cancelled). Only what is really in
    # stock is listed.
    query = (db.query(Inventory, Item.item_name, Item.unit_of_measure)
             .join(Item, Inventory.item_id == Item.item_id)
             .filter(Inventory.quantity > 0))
    if report_id is not None:
        query = query.filter(Inventory.report_id == report_id)

    results = query.order_by(Inventory.report_id, Item.item_name).all()
    labels = _report_labels(db, {inv.report_id for inv, _, _ in results})
    return [
        InventoryResponse(
            inventory_id=inv.inventory_id,
            item_id=inv.item_id,
            item_name=item_name,
            unit=unit,
            report_id=inv.report_id,
            report_label=labels.get(inv.report_id),
            quantity=inv.quantity,
            last_updated=inv.last_updated,
        )
        for inv, item_name, unit in results
    ]


def _report_labels(db: Session, report_ids) -> dict:
    if not report_ids:
        return {}
    types = {t.disaster_type_id: t.type_name for t in db.query(DisasterType).all()}
    brgys = {b.barangay_id: b.barangay_name for b in db.query(Barangay).all()}
    return {
        r.report_id: f"#{r.report_id} {r.disaster_label(types)} - {brgys.get(r.barangay_id, 'Barangay')}"
        for r in db.query(DisasterReport).filter(DisasterReport.report_id.in_(report_ids)).all()
    }


# UC-CM1 step 2: identify the donation entry by its QR reference (scanned or
# typed). Alt flow 2a: if the code cannot be read, search manually instead.
@router.get("/by-qr/{qr_reference}")
def find_by_qr(
    qr_reference: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("CSWS Main Office", "Administrator")),
):
    d = db.query(PhysicalDonation).filter(
        PhysicalDonation.qr_reference == qr_reference.strip().upper()
    ).first()
    if d is None:
        raise HTTPException(status_code=404, detail=f"No donation with reference {qr_reference}")
    item = db.get(Item, d.item_id)
    if d.user_id:
        donor_user = db.get(User, d.user_id)
        donor = f"{donor_user.first_name} {donor_user.last_name}".strip() if donor_user else "Donor"
    else:
        guest = db.get(GuestDonor, d.guest_donor_id) if d.guest_donor_id else None
        donor = f"{guest.full_name} (guest)" if guest else "Guest"
    received = db.query(ReceivedGoods).filter(ReceivedGoods.donation_id == d.donation_id).first()
    return {
        "donation_id": d.donation_id,
        "qr_reference": d.qr_reference,
        "status": d.status,
        "item_id": d.item_id,
        "item_name": item.item_name if item else None,
        "unit": item.unit_of_measure if item else None,
        "quantity": d.quantity,
        "packaging": d.packaging,
        "contents": d.contents,   # a note (Nov 22)
        "estimated_value": d.estimated_value,
        "handover_method": d.handover_method,
        "pickup_address": d.pickup_address,
        "donor": donor,
        "report_id": d.report_id,
        "report_label": _report_labels(db, {d.report_id}).get(d.report_id),
        "actual_quantity_received": received.actual_quantity if received else None,
        # G-002 (D8)
        **{k: v for k, v in donated_item_fields(
            d, item.unit_of_measure if item else "",
            received.actual_quantity if received else None).items() if k != "packaging"},
        "created_at": d.created_at,
    }


def _receive_line(db: Session, current_user: User, donation: PhysicalDonation,
                  actual_quantity: int, notes: Optional[str],
                  item_id: Optional[int] = None) -> ReceivedGoods:
    """UC-CM1 steps 3-8 for one item: record the actual quantity accepted
    (alt 4a: may be less than declared), mark it Received and add it to the
    report's inventory. Single receive and entry receive both use this.
    Does not commit."""
    if donation.status in CLOSED:
        # Plain message for the person at the counter: what happened, what to do.
        when = nice_date(donation.closed_at)
        raise HTTPException(
            status_code=400,
            detail=f"This donation was marked {donation.status}{' on ' + when if when else ''}. "
                   f"Tap Reinstate first if the donor is handing it over now.",
        )
    if donation.status != "Pending":
        raise HTTPException(status_code=400, detail=f"Donation is already '{donation.status}', cannot receive again")
    # Per-item fulfillment (Oct 2026): staff can say what the goods really
    # are before they enter the inventory. actual_quantity is then in THAT
    # item's base unit. Only counted toward a need of the same item.
    if item_id is not None and item_id != donation.item_id:
        new_item = db.get(Item, item_id)
        if new_item is None or not new_item.active:
            raise HTTPException(status_code=422, detail="Choose an item from the list.")
        log_action(db, current_user, "RECLASSIFY DONATION", "physical_donations", donation.donation_id,
                   old={"item_id": donation.item_id}, new={"item_id": item_id})
        donation.item_id = item_id
    receipt = ReceivedGoods(
        donation_id=donation.donation_id,
        actual_quantity=actual_quantity,
        received_by_user_id=current_user.user_id,
        notes=notes,
    )
    db.add(receipt)
    donation.status = "Received"
    # Same transaction as the receipt and the status change (5.1.3).
    add_received_stock(db, donation.item_id, donation.report_id, actual_quantity)
    log_action(db, current_user, "RECEIVE DONATION", "physical_donations", donation.donation_id,
               old={"status": "Pending"},
               new={"status": "Received", "declared": donation.quantity,
                    "actual_quantity": actual_quantity})
    return receipt


@router.post("/receive", response_model=ReceivedGoodsResponse)
def receive_donation(
    payload: ReceivedGoodsCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("CSWS Main Office", "Administrator")),
):
    donation = db.query(PhysicalDonation).filter(
        PhysicalDonation.donation_id == payload.donation_id
    ).with_for_update().populate_existing().first()     # F-06: a second scan waits, then sees "Received"
    if not donation:
        raise HTTPException(status_code=404, detail="Donation not found")

    receipt = _receive_line(db, current_user, donation, payload.actual_quantity, payload.notes,
                            payload.item_id)
    notify_many(db, user_ids_with_role(db, ["CMO Representative"]),
                "donation_awaiting_confirmation", "Donation awaiting acknowledgement",
                f"Donation #{donation.donation_id} was received by CSWS and needs the CMO's acknowledgement.",
                # problema_napud 4.1: tapping it opens this entry.
                entity_type="donation", entity_id=donation.donation_id)
    if donation.user_id:
        notify(db, donation.user_id, "donation_received",
               title=f"Donation entry {donation.batch_reference or donation.qr_reference} received",
               body=RECEIVED_BODY,
               entity_type="donation", entity_id=donation.donation_id)
    db.commit()
    db.refresh(receipt)
    return receipt


NOT_BROUGHT = "Not brought to CSWS"


class EntryReceiveLine(BaseModel):
    donation_id: int
    actual_quantity: int = Field(gt=0)   # in the item's base unit
    item_id: Optional[int] = None        # what it really is (see _receive_line)


class EntryReceive(BaseModel):
    items: list[EntryReceiveLine] = []
    # Oct 13 concerns: items the donor did not bring. They are closed
    # ("Not brought to CSWS", kept for the record) instead of staying
    # Pending, so the entry reads Received, not Partly Received.
    not_brought: list[int] = []
    notes: Optional[str] = None


# UC-CM1 for a whole entry (one QR = one batch_reference): every listed item
# is received with its actual quantity in one transaction, so either all of
# them reach the inventory or none do. Items left out stay Pending
# (alt 4b: not accepted).
@router.post("/entries/{batch_reference}/receive")
def receive_entry(
    batch_reference: str,
    payload: EntryReceive,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("CSWS Main Office", "Administrator")),
):
    ref = batch_reference.strip().upper()
    rows = {
        d.donation_id: d
        for d in db.query(PhysicalDonation).filter(PhysicalDonation.batch_reference == ref)
        .order_by(PhysicalDonation.donation_id)
        .with_for_update().populate_existing().all()     # F-06: one receive of this entry at a time
    }
    if not rows:
        raise HTTPException(status_code=404, detail=f"No donation entry {batch_reference}")
    ids = [line.donation_id for line in payload.items]
    if not ids and not payload.not_brought:
        raise HTTPException(status_code=400, detail="Enter what was received, or mark the items that were not brought.")
    every = ids + list(payload.not_brought)
    if len(set(every)) != len(every):
        raise HTTPException(status_code=400, detail="Each item can be listed only once")
    for donation_id in every:
        if donation_id not in rows:
            raise HTTPException(status_code=400, detail=f"Donation #{donation_id} is not part of entry {ref}")
    for donation_id in payload.not_brought:
        if rows[donation_id].status != "Pending":
            raise HTTPException(status_code=409, detail=f"Donation #{donation_id} is no longer waiting, so it cannot be marked not brought.")

    # F-06: stock rows are locked in item order, like deliveries do.
    for line in sorted(payload.items, key=lambda l: l.item_id or rows[l.donation_id].item_id):
        _receive_line(db, current_user, rows[line.donation_id], line.actual_quantity, payload.notes,
                      line.item_id)
    closed = close_rows([rows[i] for i in payload.not_brought], "Cancelled", NOT_BROUGHT,
                        user_id=current_user.user_id)
    for r in closed:
        log_action(db, current_user, "NOT BROUGHT", "physical_donations", r.donation_id,
                   old={"status": "Pending"}, new={"status": "Cancelled", "reason": NOT_BROUGHT})
    if not ids:
        db.commit()
        return {"batch_reference": ref, "received": [], "not_brought": list(payload.not_brought),
                "pending_items": sum(1 for d in rows.values() if d.status == "Pending")}

    first = next(iter(rows.values()))
    notify_many(db, user_ids_with_role(db, ["CMO Representative"]),
                "donation_awaiting_confirmation", "Donation awaiting acknowledgement",
                f"Donation {ref} ({len(ids)} item(s)) was received by CSWS and needs the CMO's acknowledgement.",
                # problema_napud 4.1: tapping it opens this entry.
                entity_type="donation", entity_id=ids[0])
    if first.user_id:
        notify(db, first.user_id, "donation_received",
               title=f"Donation entry {ref} received",
               body=RECEIVED_BODY,
               entity_type="donation", entity_id=ids[0])
    db.commit()
    still_pending = sum(1 for d in rows.values() if d.status == "Pending")
    return {
        "batch_reference": ref,
        "received": [
            {"donation_id": line.donation_id, "actual_quantity": line.actual_quantity}
            for line in payload.items
        ],
        "not_brought": list(payload.not_brought),
        "pending_items": still_pending,
    }


# NOTE (6.1): the old POST /donations/{donation_id}/confirm route was removed.
# Official recognition ("Confirmed") belongs ONLY to the CMO, via
# POST /cmo/donations/{donation_id}/confirm in cmo_router.py (manuscript Fig. 14).
# CSWS receiving ends at status "Received".


# ---------------------------------------------------------------------------
# Module 4.4 / 4.5 donation records (Hoyohoy). NF-003 paging lives only in
# this block; the CSWS receiving / inventory endpoints above are untouched.
# ---------------------------------------------------------------------------
from fastapi import Response  # noqa: E402  (NF-003: kept with this block)
from core.shared.pagination import PageParams, set_total_header  # noqa: E402
from core.m4_donation_management.entry_paging import entry_counts, page_entries, report_groups  # noqa: E402

# Not an entry status: an entry with an item the CMO put on hold. The app's
# "Needs attention" card filters on it, so the paged list must too.
ON_HOLD = "On Hold"


def _scoped_entries(db: Session, current_user: User, report_id: Optional[int] = None,
                    disaster_type_id: Optional[int] = None) -> list:
    """Every entry the caller may see, numbered per report (Donation 1, 2 ...)
    on the FULL list, so a later page still shows the right numbers.
    disaster_type_id (NF-001) keeps whole reports, so numbers do not change."""
    expire_overdue(db)
    own_barangay = barangay_scope(current_user)
    query = db.query(PhysicalDonation)
    if own_barangay is not None or disaster_type_id is not None:
        query = query.join(DisasterReport, DisasterReport.report_id == PhysicalDonation.report_id)
    if own_barangay is not None:
        query = query.filter(DisasterReport.barangay_id == own_barangay)
    if disaster_type_id is not None:
        query = query.filter(DisasterReport.disaster_type_id == disaster_type_id)
    if report_id is not None:
        query = query.filter(PhysicalDonation.report_id == report_id)
    staff = own_barangay is None
    entries = build_entries(db, query.all(), include_donor=staff, include_cmo=staff)
    group_by_report(entries)  # numbers each report's entries (Donation 1, 2 ...)
    return entries


def _is_on_hold(status: Optional[str]) -> bool:
    return bool(status) and status.strip().lower() == ON_HOLD.lower()


@router.get("/records")
def donation_records(
    response: Response,
    status: Optional[str] = None,
    report_id: Optional[int] = None,
    handover_method: Optional[str] = None,
    q: Optional[str] = None,
    sort: str = Query("newest", pattern="^(" + "|".join(ENTRY_SORTS) + ")$"),
    include_closed: bool = False,
    disaster_type_id: Optional[int] = None,
    page: PageParams = Depends(),
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(
        "Administrator", "CSWS Main Office", "CMO Representative", "barangay_receiving_rep",
    )),
):
    """Appendix H, Module 4.4 / 4.5: View donation records and monitor
    donation status (Administrator, CSWS Main Office, CMO, Barangay
    Receiving Representative).

    A Barangay Receiving Representative only gets the donations for reports
    in its own assigned barangay (UC-B1 alt 3a), without donor names or CMO
    notes: it follows what is coming for its barangay, not who gave it.

    One record per donation entry (one QR / batch_reference) with its items.
    Filters: status (entry status, or "On Hold" = has an item the CMO put on
    hold), report_id, handover_method, q (QR reference, donor or item).
    sort: newest, oldest, most_items, fewest_items, due_soonest; every sort
    ends on the entry's first donation_id, so the order is always the same.

    Expired / Cancelled entries are hidden unless status asks for them
    (status=Expired, Cancelled or Closed) or include_closed=true, so the
    everyday list only shows donations that still need work.

    NF-001: optional disaster_type_id (the report's type); an unknown id
    gives an empty list. NF-003: optional limit / offset. With limit the database groups,
    filters, sorts and pages the entries (core/m4_donation_management/entry_paging.py) and only
    the page's entries are built; X-Total-Count holds the total. Without
    limit the answer is exactly as before (installed APKs send no limit).
    """
    if page.requested:
        expire_overdue(db)
        rows, total = page_entries(
            db, current_user, offset=page.offset, limit=page.limit,
            status=status, report_id=report_id, handover_method=handover_method,
            search=q, sort=sort, include_closed=include_closed,
            disaster_type_id=disaster_type_id,
        )
        set_total_header(response, page, total)
        # Nov 24: "View receipt" for each delivery the barangay confirmed.
        return add_receipts(db, rows)

    entries = _scoped_entries(db, current_user, report_id, disaster_type_id)
    if not status and not include_closed:
        entries = [e for e in entries if e["status"] not in CLOSED]
    if _is_on_hold(status):
        entries = [e for e in entries if (e.get("on_hold_items") or 0) > 0]
        status = None
    # Without limit the answer stays byte for byte the old one (installed
    # APKs); the app's paged lists get receipt_deliveries above.
    return filter_and_sort(entries, status=status, handover_method=handover_method, search=q, sort=sort)


@router.get("/records/counts")
def donation_record_counts(
    report_id: Optional[int] = None,
    handover_method: Optional[str] = None,
    q: Optional[str] = None,
    include_closed: bool = False,
    disaster_type_id: Optional[int] = None,
    status: Optional[str] = None,  # accepted so the app can send the list's filters as they are
    sort: Optional[str] = None,    # same; counting does not depend on the order
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(
        "Administrator", "CSWS Main Office", "CMO Representative", "barangay_receiving_rep",
    )),
):
    """NF-003: the numbers for the records screen's status chips and "Needs
    attention" card, now that the list arrives one page at a time.

    Takes the same filters as GET /donations/records (report_id,
    handover_method, q, include_closed). status is ignored on purpose: each
    chip counts the entries it would show when picked. Same role scope as the
    list (a Barangay Receiving Representative counts only its own barangay).

    all:       what the list shows with no status picked
    by_status: entries per status, plus "On Hold"
    reports:   the reports that have entries in the caller's scope, newest
               first, for the Report dropdown
    """
    expire_overdue(db)
    return entry_counts(
        db, current_user, report_id=report_id, handover_method=handover_method,
        search=q, include_closed=include_closed, disaster_type_id=disaster_type_id,
    )


@router.get("/records/per-report")
def donation_records_per_report(
    response: Response,
    disaster_type_id: Optional[int] = None,
    include_closed: bool = True,
    page: PageParams = Depends(),
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(
        "Administrator", "CSWS Main Office", "CMO Representative", "barangay_receiving_rep",
    )),
):
    """NF-001 / NF-003: the records screen's "Per report" view (Module 4.4).
    One row per report with entries in the caller's scope, newest first:
    {report_id, report_label, total_entries, by_status}. Grouped in SQL and
    paged with limit / offset (X-Total-Count), filtered by disaster type.
    Same roles and barangay scope as GET /donations/records."""
    expire_overdue(db)
    rows, total = report_groups(
        db, current_user, offset=page.offset, limit=page.limit,
        disaster_type_id=disaster_type_id, include_closed=include_closed,
    )
    set_total_header(response, page, total)
    return rows


# ---------------------------------------------------------------------------
# NF-003 (CSWS Main Office): the Receive screen's tabs, 20 rows per page.
# Same rows as before (GET /donations/entries?pending_only=true,
# GET /donations/records, GET /donations/inventory), with the screen's
# filters and sorts applied here (core/m5_inventory/receive_queue.py).
# ---------------------------------------------------------------------------
from core.shared.pagination import paginate_list  # noqa: E402
from core.m5_inventory import receive_queue  # noqa: E402


def _receive_sources(db: Session, current_user: User):
    """Pending groups, received entries and stock rows, as the three old
    endpoints sent them, plus each report's priority."""
    entries = _scoped_entries(db, current_user)
    groups = group_by_report([dict(e) for e in entries], pending_only=True)
    records = [e for e in entries if e["status"] not in CLOSED]
    stock = [r.model_dump() for r in view_inventory(report_id=None, db=db, current_user=current_user)]
    ids = {g["report_id"] for g in groups}
    priorities = {r.report_id: r.priority_level
                  for r in db.query(DisasterReport).filter(DisasterReport.report_id.in_(ids))} if ids else {}
    return groups, records, stock, priorities


@router.get("/receive-queue")
def receive_queue_page(
    response: Response,
    tab: str = Query(default="pending"),
    barangay: Optional[str] = Query(default=None, max_length=100),
    report_id: Optional[int] = None,
    handover: Optional[str] = Query(default=None, max_length=30),
    status: Optional[str] = Query(default=None, max_length=30, description="Received tab only"),
    when: str = Query(default="any"),
    tz: int = Query(default=480, ge=-720, le=840, description="Phone's UTC offset in minutes"),
    q: Optional[str] = Query(default=None, max_length=100),
    sort: str = Query(default="urgent"),
    inventory_sort: str = Query(default="item_az"),
    page: PageParams = Depends(),
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("CSWS Main Office", "Administrator")),
):
    """One tab of the Receive screen, filtered, sorted and a page at a time
    (X-Total-Count): pending entries (grouped by report in the app), received
    entries, or stock rows (grouped by report)."""
    receive_queue.check(tab, sort, when, inventory_sort)
    groups, records, stock, priorities = _receive_sources(db, current_user)
    if tab == "pending":
        rows = receive_queue.pending_rows(groups, priorities, barangay=barangay, report_id=report_id,
                                          handover=handover, when=when, tz=tz, search=q, sort=sort)
    elif tab == "received":
        rows = receive_queue.received_rows(records, barangay=barangay, report_id=report_id, handover=handover,
                                           status=status, when=when, tz=tz, search=q, sort=sort)
    else:
        rows = receive_queue.inventory_rows(stock, barangay=barangay, report_id=report_id, search=q,
                                            sort=inventory_sort)
    rows, total = paginate_list(rows, page)
    set_total_header(response, page, total)
    return rows


@router.get("/receive-queue/summary")
def receive_queue_summary(
    barangay: Optional[str] = Query(default=None, max_length=100),
    report_id: Optional[int] = None,
    handover: Optional[str] = Query(default=None, max_length=30),
    status: Optional[str] = Query(default=None, max_length=30),
    when: str = Query(default="any"),
    tz: int = Query(default=480, ge=-720, le=840),
    q: Optional[str] = Query(default=None, max_length=100),
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("CSWS Main Office", "Administrator")),
):
    """The tab labels ("Pending (12)"), the "shown of total" line and the
    Barangay / Report dropdowns, for the same filters."""
    receive_queue.check("pending", "urgent", when, "item_az")
    groups, records, stock, priorities = _receive_sources(db, current_user)
    pending = receive_queue.pending_rows(groups, priorities, barangay=barangay, report_id=report_id,
                                         handover=handover, when=when, tz=tz, search=q)
    received = receive_queue.received_rows(records, barangay=barangay, report_id=report_id,
                                           handover=handover, status=status, when=when, tz=tz, search=q)
    stock_shown = receive_queue.inventory_rows(stock, barangay=barangay, report_id=report_id)
    received_all = [e for e in records if e["status"] != "Pending"]
    everything = [*groups, *received_all, *stock]
    barangays, reports = receive_queue.options(everything, barangay)
    return {
        "pending": {"shown": len(pending), "total": sum(len(g["entries"]) for g in groups)},
        "received": {"shown": len(received), "total": len(received_all)},
        "inventory": {"shown": len(stock_shown), "total": len(stock),
                      "reports": len({r["report_id"] for r in stock_shown})},
        "barangays": barangays,
        "reports": reports,
    }

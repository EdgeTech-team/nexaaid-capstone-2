from pydantic import BaseModel
from typing import List, Optional

class StatusCount(BaseModel):
    status: str
    count: int

class PriorityCount(BaseModel):
    priority_level: Optional[str]
    count: int

class DashboardSummary(BaseModel):
    total_reports: int
    total_donations: int
    total_deliveries: int
    total_logistics_requests: int
    active_organizations: int

class ReportsBreakdown(BaseModel):
    by_status: List[StatusCount]
    by_priority: List[PriorityCount]
    total_estimated_value: float = 0

class DonationBreakdown(BaseModel):
    by_status: List[StatusCount]
    total_estimated_value: float

class FulfillmentOverview(BaseModel):
    average_fulfillment_percentage: float
    fully_verified_count: int
    pending_verification_count: int

class LogisticsOverview(BaseModel):
    deliveries_by_status: List[StatusCount]
    requests_by_status: List[StatusCount]

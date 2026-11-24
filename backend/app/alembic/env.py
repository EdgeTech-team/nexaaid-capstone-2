from logging.config import fileConfig
from sqlalchemy import engine_from_config
from sqlalchemy import pool
from alembic import context

from core.shared.config import settings
from core.shared.database import Base

from core.m1_user_management.user_rbac_model import User
from core.m1_user_management.role_model import Role
from core.m1_user_management.organization_model import Organization
from core.reference_data.item_model import Item
from core.m4_donation_management.physical_donation_model import PhysicalDonation
from core.m5_inventory.received_goods_model import ReceivedGoods
from core.m5_inventory.inventory_model import Inventory
from core.m2_disaster_reporting.report_model import DisasterReport 
from core.reference_data.city_model import City
from core.reference_data.barangay_model import Barangay
from core.reference_data.disaster_type_model import DisasterType
from core.reference_data.sitio_model import Sitio
from core.reference_data.barangay_hazard_model import BarangayHazard
from core.m2_disaster_reporting.disaster_event_model import DisasterEvent

from core.m4_donation_management.guest_donor_model import GuestDonor
from core.shared.upload_model import Upload
from core.m4_donation_management.donation_info_model import BarangayDonationInfo, ReportDonationInfo


# this is the Alembic Config object, which provides
# access to the values within the .ini file in use.
config = context.config

# Interpret the config file for Python logging.
# This line sets up loggers basically.
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

# add your model's MetaData object here
# for 'autogenerate' support
# from myapp import mymodel
# target_metadata = mymodel.Base.metadata
config.set_main_option("sqlalchemy.url", settings.DIRECT_URL)
target_metadata = Base.metadata

# other values from the config, defined by the needs of env.py,
# can be acquired:
# my_important_option = config.get_main_option("my_important_option")
# ... etc.

def include_object(object, name, type_, reflected, compare_to):
    if type_ == "table" and reflected and compare_to is None:
        return False
    return True


def run_migrations_offline() -> None:
    """Run migrations in 'offline' mode."""
    url = config.get_main_option("sqlalchemy.url")
    context.configure(
        url=url,
        target_metadata=target_metadata,
        include_object=include_object,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )

    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    """Run migrations in 'online' mode."""
    connectable = engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )

    with connectable.connect() as connection:
        context.configure(
            connection=connection,
            target_metadata=target_metadata,
            include_object=include_object,
        )

        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
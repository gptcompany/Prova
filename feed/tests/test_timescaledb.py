import asyncio
import asyncpg
from datetime import datetime, timezone
import time
import yaml
with open('/config_cf.yaml', 'r') as file:
    config = yaml.safe_load(file)
    
postgres_cfg = {
            'host': '0.0.0.0', 
            'user': 'postgres', 
            'db': 'db0', 
            'pw': config['timescaledb_password'], 
            'port': '5432',
                        }
async def fetch_latest_receipts(table, user, pw, db, host, port):
    conn = await asyncpg.connect(user=user, password=pw, database=db, host=host, port=port)
    try:
        result = await conn.fetch(f"""
            SELECT symbol, MAX(receipt) AS latest_receipt
            FROM {table}
            GROUP BY symbol
            ORDER BY symbol;
        """)
        return result
    finally:
        await conn.close()

def utc_to_local(utc_dt):
    # Get the local timezone offset
    local_timezone = datetime.now(timezone.utc).astimezone().tzinfo
    local_dt = utc_dt.replace(tzinfo=timezone.utc).astimezone(local_timezone)
    return local_dt

def format_datetime(dt):
    # Format the datetime object to a string
    return dt.strftime("%Y-%m-%d %H:%M:%S %Z")

async def main():
    trades_receipts = await fetch_latest_receipts('trades', **postgres_cfg)
    print("Latest Receipts in Trades Table:")
    for record in trades_receipts:
        utc_dt = record['latest_receipt']
        local_dt = utc_to_local(utc_dt)
        formatted_dt = format_datetime(local_dt)
        print(f"Symbol: {record['symbol']}, Latest Receipt: {formatted_dt}")

    book_receipts = await fetch_latest_receipts('book', **postgres_cfg)
    print("\nLatest Receipts in Book Table:")
    for record in book_receipts:
        utc_dt = record['latest_receipt']
        local_dt = utc_to_local(utc_dt)
        formatted_dt = format_datetime(local_dt)
        print(f"Symbol: {record['symbol']}, Latest Receipt: {formatted_dt}")
        
        
        
if __name__ == "__main__":
    asyncio.run(main())

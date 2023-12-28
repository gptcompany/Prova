import asyncio
import asyncpg
from datetime import datetime, timezone
import time
import logging
import yaml
with open('/config_cf.yaml', 'r') as file:
    config = yaml.safe_load(file)
    
postgres_cfg = {
            'host': '0.0.0.0', 
            'user': 'postgres', 
            'database': 'db0', 
            'password': config['timescaledb_password'], 
            'port': '5432',
                        }
async def check_data_persistence_for_multiple_pairs(table, columns, minutes, exchanges, symbols, **postgres_cfg):
    conn = await asyncpg.connect(**postgres_cfg)
    persistence_results = {}
    try:
        non_null_conditions = ' AND '.join([f"{col} IS NOT NULL" for col in columns])
        for exchange in exchanges:
            for symbol in symbols:
                query = f"""
                    SELECT COUNT(*) 
                    FROM {table}
                    WHERE {non_null_conditions}
                    AND exchange = $1 AND symbol = $2
                    AND receipt > (NOW() - INTERVAL '{minutes} minutes')
                """
                count = await conn.fetchval(query, exchange, symbol)
                persistence_results[(exchange, symbol)] = count > 0
    finally:
        await conn.close()
    return persistence_results


async def fetch_latest_receipts_for_multiple_pairs(table, exchanges, symbols, **postgres_cfg):
    conn = await asyncpg.connect(**postgres_cfg)
    results = []
    try:
        for exchange in exchanges:
            for symbol in symbols:
                query = f"""
                    SELECT symbol, MAX(receipt) AS latest_receipt
                    FROM {table}
                    WHERE exchange = $1 AND symbol = $2
                    GROUP BY symbol;
                """
                result = await conn.fetch(query, exchange, symbol)
                results.extend(result)  # Aggregate results from each query
    finally:
        await conn.close()
    return results


def utc_to_local(utc_dt):
    # Get the local timezone offset
    local_timezone = datetime.now(timezone.utc).astimezone().tzinfo
    local_dt = utc_dt.replace(tzinfo=timezone.utc).astimezone(local_timezone)
    return local_dt

def format_datetime(dt):
    # Format the datetime object to a string
    return dt.strftime("%Y-%m-%d %H:%M:%S %Z")

def check_receipt_age(latest_receipt):
    current_time = datetime.now(timezone.utc)
    time_diff = current_time - latest_receipt

    if time_diff.total_seconds() > 60:  # Older than 1 minute
        logging.warning(f"Latest receipt is older than 1 minute: {latest_receipt}")
    else:
        logging.info("All OK: Latest receipt is within 1 minute.")

async def main():
    logging.basicConfig(level=logging.INFO)
    symbols = config['bn_symbols']
    exchanges = ['BITFINEX', 'BINANCE']
    
    trades_receipts = await fetch_latest_receipts_for_multiple_pairs('trades', exchanges, symbols, **postgres_cfg)
    print("Latest Receipts in Trades Table:")
    for record in trades_receipts:
        utc_dt = record['latest_receipt']
        local_dt = utc_to_local(utc_dt)
        formatted_dt = format_datetime(local_dt)
        print(f"Symbol: {record['symbol']}, Latest Receipt: {formatted_dt}")
        check_receipt_age(utc_dt)

    book_receipts = await fetch_latest_receipts_for_multiple_pairs('book', exchanges, symbols, **postgres_cfg)
    print("\nLatest Receipts in Book Table:")
    for record in book_receipts:
        utc_dt = record['latest_receipt']
        local_dt = utc_to_local(utc_dt)
        formatted_dt = format_datetime(local_dt)
        print(f"Symbol: {record['symbol']}, Latest Receipt: {formatted_dt}")
        check_receipt_age(utc_dt)

    
    columns_book = ['exchange', 'symbol', 'receipt', 'data', 'update_type']
    columns_trades = ['exchange', 'symbol', 'timestamp', 'receipt', 'side', 'amount', 'price', 'id']

    # Check data persistence for multiple pairs
    trade_data_persistence = await check_data_persistence_for_multiple_pairs('trades', columns_trades, 30, exchanges, symbols, **postgres_cfg)
    book_data_persistence = await check_data_persistence_for_multiple_pairs('book', columns_book, 30, exchanges, symbols, **postgres_cfg)
    for pair, is_persisted in trade_data_persistence.items():
        exchange, symbol = pair
        status = 'Yes' if is_persisted else 'No'
        print(f"Data persisted for {exchange}-{symbol} in 'trades' table in the last 30 minutes: {status}")

    for pair, is_persisted in book_data_persistence.items():
        exchange, symbol = pair
        status = 'Yes' if is_persisted else 'No'
        print(f"Data persisted for {exchange}-{symbol} in 'book' table in the last 30 minutes: {status}")

        
if __name__ == "__main__":
    asyncio.run(main())

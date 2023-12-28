import asyncio
import asyncpg
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

async def main():
    trades_receipts = await fetch_latest_receipts('trades', **postgres_cfg)
    print("Latest Receipts in Trades Table:")
    for record in trades_receipts:
        print(record)

    book_receipts = await fetch_latest_receipts('book', **postgres_cfg)
    print("\nLatest Receipts in Book Table:")
    for record in book_receipts:
        print(record)
        
        
        
if __name__ == "__main__":
    asyncio.run(main())

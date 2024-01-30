import asyncio
import psycopg2
from redis import asyncio as aioredis
import json

async def fetch_data_from_redis(redis_uri, key_pattern):
    conn = await aioredis.from_url(redis_uri, decode_responses=True)
    data = []
    # Example for Redis streams
    streams = await conn.xrange(key_pattern, count=1000)
    for message in streams:
        data.append(json.loads(message[1]))  # Assuming data is JSON encoded
    await conn.close()
    return data


def insert_data_to_timescaledb(db_params, data, table):
    with psycopg2.connect(**db_params) as conn:
        with conn.cursor() as cursor:
            # Assuming data is a list of tuples matching the table schema
            psycopg2.extras.execute_batch(cursor, f"INSERT INTO {table} VALUES (%s, %s, ...)", data)


async def main():
    while True:
        data = await fetch_data_from_redis('redis://localhost', 'your_key_pattern')
        transformed_data = transform_data(data)  # Define this function based on your needs
        insert_data_to_timescaledb({'dbname': 'db_name', 'user': 'username'}, transformed_data, 'your_table')
        await asyncio.sleep(60)  # Wait for 60 seconds or your desired interval

if __name__ == '__main__':
    asyncio.run(main())

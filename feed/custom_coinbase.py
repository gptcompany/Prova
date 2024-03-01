from cryptofeed.exchanges import Coinbase
from cryptofeed.connection import AsyncConnection, RestEndpoint, Routes, WebsocketEndpoint
from cryptofeed.defines import  L3_BOOK
import time
import hashlib
import json
import hmac 
import base64
# import logging
import asyncio
# logging.basicConfig(filename='cryptofeed.log', level=logging.INFO, format='%(asctime)s:%(levelname)s:%(message)s')
# logger = logging.getLogger(__name__)


class CustomCoinbase(Coinbase):
    #websocket_endpoints = [WebsocketEndpoint('wss://ws-feed.pro.coinbase.com', options={'compression': None})]
    def __init__(self, callbacks=None, **kwargs):
        super().__init__(callbacks=callbacks, **kwargs)
        # we only keep track of the L3 order book if we have at least one subscribed order-book callback.
        # use case: subscribing to the L3 book plus Trade type gives you order_type information (see _received below),
        # and we don't need to do the rest of the book-keeping unless we have an active callback
        self.keep_l3_book = False
        if callbacks and L3_BOOK in callbacks:
            self.keep_l3_book = True
        self.__reset()

    def __reset(self):
        self.order_map = {}
        self.order_type_map = {}
        self.seq_no = None
        # sequence number validation only works when the FULL data stream is enabled
        chan = self.std_channel_to_exchange(L3_BOOK)
        if chan in self.subscription:
            pairs = self.subscription[chan]
            self.seq_no = {pair: None for pair in pairs}
        self._l3_book = {}
        self._l2_book = {}
            
        
    async def subscribe(self, conn: AsyncConnection):
        self.__reset()
        #await asyncio.sleep(0.3)
        
        method =  'GET'
        request_path = "/users/self/verify"
        key = self.config['coinbase']['key_id']  #TODO: Try self.config['coinbase']['key_id'] instead of fh.config.config
        key_passphrase = self.config['coinbase']['key_passphrase']
        key_secret = self.config['coinbase']['key_secret']
        # print("Key:", key)
        # print("Passphrase:", key_passphrase)
        # print("Secret Key:", key_secret)
        timestamp = str(int(time.time()))
        message = timestamp + method + request_path
        hmac_key = base64.b64decode(key_secret)
        signature = hmac.new(hmac_key, message.encode(), hashlib.sha256)
        signature_b64 = base64.b64encode(signature.digest())
        for chan in self.subscription:
                
                await conn.write(json.dumps({"type": "subscribe",
                                            "product_ids": list(self.subscription[chan]),
                                            "channels": [chan],
                                            "signature": signature_b64.decode(),
                                            "key": key,
                                            "passphrase":key_passphrase,
                                            "timestamp":timestamp,
                                            }))
        chan = self.std_channel_to_exchange(L3_BOOK)
        if chan in self.subscription:
            #await asyncio.sleep(0.3)
            await self._book_snapshot(self.subscription[chan])
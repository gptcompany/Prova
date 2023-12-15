from cryptofeed import FeedHandler
from cryptofeed.exchanges import Coinbase, Binance, Bitfinex
import sys
import logging
logging.basicConfig(stream=sys.stdout, level=logging.INFO, format='%(asctime)s:%(levelname)s:%(message)s')
logger = logging.getLogger(__name__)
def nbbo_update(symbol, bid, bid_size, ask, ask_size, bid_feed, ask_feed):
    print(f'Pair: {symbol} Bid Price: {bid:.2f} Bid Size: {bid_size:.6f} Bid Feed: {bid_feed} Ask Price: {ask:.2f} Ask Size: {ask_size:.6f} Ask Feed: {ask_feed}')


def main():
    path_to_config = '/config_cf.yaml'
    f = FeedHandler(config=path_to_config)  
    #symbols = fh.config.config['bf_symbols']
    symbols = ['BTC-USDT']
    f.add_nbbo([Binance, Bitfinex], symbols, nbbo_update)
    f.run()
    
if __name__ == '__main__':
    main()
    
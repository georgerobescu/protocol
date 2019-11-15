const fs = require('fs');
const web3 = require('./get-web3');
const nab = require('./deploy-contract').nab;
const deploy = require('./deploy-contract').deploy;
const deployIn = require('./get-deploy-input');

const deploy_in = './deploy_in.json'; // TODO: rename
const deploy_out = './deploy_out.json'; // TODO: rename

const main = async input => {
  const tokenAddrs = input.tokens.addr;
  const weth = await nab('WETH', [], tokenAddrs);
  const mln = await nab('BurnableToken', ['MLN', 18, 'Melon Token'], tokenAddrs, 'MLN');
  const bat = await nab('PreminedToken', ['BAT', 18, ''], tokenAddrs, 'BAT');
  const dai = await nab('PreminedToken', ['DAI', 18, ''], tokenAddrs, 'DAI');
  const dgx = await nab('PreminedToken', ['DGX', 18, ''], tokenAddrs, 'DGX');
  const eur = await nab('PreminedToken', ['EUR', 18, ''], tokenAddrs, 'EUR');
  const knc = await nab('PreminedToken', ['KNC', 18, ''], tokenAddrs, 'KNC');
  const mkr = await nab('PreminedToken', ['MKR', 18, ''], tokenAddrs, 'MKR');
  const rep = await nab('PreminedToken', ['REP', 18, ''], tokenAddrs, 'REP');
  const zrx = await nab('PreminedToken', ['ZRX', 18, ''], tokenAddrs, 'ZRX');

  return {
    "WETH": weth.options.address,
    "MLN": mln.options.address,
    "BAT": bat.options.address,
    "DAI": dai.options.address,
    "DGX": dgx.options.address,
    "EUR": eur.options.address,
    "KNC": knc.options.address,
    "MKR": mkr.options.address,
    "REP": rep.options.address,
    "ZRX": zrx.options.address,
  };
}

if (require.main === module) {
  const input = JSON.parse(fs.readFileSync(deploy_in, 'utf8'));
  main(input).then(addrs => {
    const output = Object.assign({}, input);
    output.tokens.addr = addrs;
    fs.writeFileSync(deploy_out, JSON.stringify(output, null, '  '));
    console.log(`Written to ${deploy_out}`);
    console.log(addrs);
    process.exit(0);
  }).catch(e => { console.error(e); process.exit(1) });
}

module.exports = main;

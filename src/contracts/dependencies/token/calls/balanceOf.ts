import { createQuantity } from '@melonproject/token-math/quantity';

import { Contract, callFactory } from '~/utils/solidity';

import { getToken } from '..';

const prepareArgs = ({ address }) => [address.toString()];
const postProcess = async (result, prepared, environment) => {
  const tokenMathToken = await getToken(prepared.contractAddress, environment);
  const quantity = createQuantity(tokenMathToken, result.toString());
  return quantity;
};

export const balanceOf = callFactory('balanceOf', Contract.PreminedToken, {
  postProcess,
  prepareArgs,
});

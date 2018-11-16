import * as R from 'ramda';
import * as Web3EthAbi from 'web3-eth-abi';
import {
  QuantityInterface,
  createQuantity,
} from '@melonproject/token-math/quantity';

import { Contracts } from '~/Contracts';

import { Environment, getGlobalEnvironment } from '../environment';
import {
  getContract,
  prepareTransaction,
  OptionsOrCallback,
  Options,
} from '../solidity';
import { Address } from '../types';

type TransactionArg = number | string;
type TransactionArgs = TransactionArg[];

// The raw unsigned transaction object from web3
// https://web3js.readthedocs.io/en/1.0/web3-eth.html#sendtransaction
export interface UnsignedRawTransaction {
  from: string;
  to: string;
  value?: string;
  gas?: string;
  gasPrice?: string;
  data?: string;
  nonce?: number;
}

export interface MelonTransaction<Args> {
  amguInEth: QuantityInterface;
  params: Args;
  rawTransaction: UnsignedRawTransaction;
  // Already signed transaction in HEX as described here:
  // https://web3js.readthedocs.io/en/1.0/web3-eth.html#sendsignedtransaction
  // If not specified, signing will be done through web3.js
  signedTransaction?: string;
  transactionArgs: TransactionArgs;
}

// Guard check if the given transaction can run without errors
// They are crucial to spot "Transaction Execution Errors" before
// the transaction actually hit the nodes. They should throw Errors with
// meaningful messages
export type GuardFunction<Args> = (
  params?: Args,
  contractAddress?: Address,
  environment?: Environment,
) => Promise<void>;

// Translates JavaScript/TypeScript params into the form that the EVM
// understands: token-math structs, ...
export type PrepareArgsFunction<Args> = (
  params: Args,
  contractAddress?: Address,
  environment?: Environment,
) => Promise<TransactionArgs>;

// Takes the transaction receipt from the EVM, checks if everything is as
// expected and returns a meaningful object
export type PostProcessFunction<Args, Result> = (
  receipt,
  params?: Args,
  contractAddress?: Address,
  environment?: Environment,
) => Promise<Result>;

export type TransactionFactory = <Args, Result>(
  name: string,
  contract: Contracts,
  guard?: GuardFunction<Args>,
  prepareArgs?: PrepareArgsFunction<Args>,
  postProcess?: PostProcessFunction<Args, Result>,
  providedOptions?: OptionsOrCallback,
) => EnhancedExecute<Args, Result>;

type SendFunction<Args> = (
  contractAddress: Address,
  melonTransaction: MelonTransaction<Args>,
  params: Args,
  providedOptions: OptionsOrCallback,
  environment: Environment,
) => Promise<any>;

type PrepareFunction<Args> = (
  contractAddress: Address,
  params?: Args,
  environment?: Environment,
) => Promise<MelonTransaction<Args>>;

type ExecuteFunction<Args, Result> = (
  contractAddress: Address,
  params?: Args,
  environment?: Environment,
) => Promise<Result>;

export interface ExecuteMixin<Args> {
  send: SendFunction<Args>;
  prepare: PrepareFunction<Args>;
}

export type EnhancedExecute<Args, Result> = ExecuteFunction<Args, Result> &
  ExecuteMixin<Args>;

export type ExecuteFunctionWithoutContractAddress<Args, Result> = (
  params?: Args,
  environment?: Environment,
) => Promise<Result>;

export type ImplicitExecute<
  Args,
  Result
> = ExecuteFunctionWithoutContractAddress<Args, Result> & ExecuteMixin<Args>;

export type WithContractAddressQuery = <Args, Result>(
  contractAddressQuery: string[],
  transaction: EnhancedExecute<Args, Result>,
) => ImplicitExecute<Args, Result>;

export const defaultGuard: GuardFunction<any> = async () => {};

export const defaultPrepareArgs = async (
  params,
  contractAddress,
  environment,
) => Object.values(params || {}).map(v => v.toString());
export const defaultPostProcess: PostProcessFunction<any, any> = async () =>
  true;

/**
 * The transaction factory returns a function "execute" (You have to rename it
 * to the actual name of the transaction, for example: "transfer"). As a
 * minimum, one needs to provide the transaction name and the contract path:
 *
 * ```typescript
 * const transfer = transactionFactory('transfer', Contract.Token);
 * ```
 *
 * This transfer function can then be executed directly:
 *
 * ```typescript
 * await transfer(new Address('0xdeadbeef'));
 * ```
 *
 * Or sliced into a prepare and a send part:
 * ```typescript
 * const preparedTransaction: PreparedTransaction =
 *    await transfer.prepare(new Address('0xdeadbeef'));
 *
 * // pass that prepared transaction to the signer
 * const result = await transfer.send(new Address('0xdeadbeef'),
 *    preparedTransaction);
 * ```
 */
const transactionFactory: TransactionFactory = <Args, Result>(
  name,
  contract,
  guard = defaultGuard,
  prepareArgs = defaultPrepareArgs,
  postProcess = defaultPostProcess,
  providedOptions = {},
) => {
  const prepare: PrepareFunction<Args> = async (
    contractAddress,
    params,
    environment: Environment = getGlobalEnvironment(),
  ) => {
    await guard(params, contractAddress, environment);
    const args = await prepareArgs(params, contractAddress, environment);
    const contractInstance = getContract(contract, contractAddress);
    const transaction = contractInstance.methods[name](...args);
    transaction.name = name;
    const prepared = await prepareTransaction(
      transaction,
      providedOptions,
      environment,
    );
    const options: Options =
      typeof providedOptions === 'function'
        ? providedOptions(prepared, environment)
        : providedOptions;

    // HACK: To avoid circular dependencies (?)
    const {
      calcAmguInEth,
    } = await import('~/contracts/engine/calls/calcAmguInEth');

    const amguInEth = options.amguPayable
      ? await calcAmguInEth(
          contractAddress,
          prepared.gasEstimation,
          environment,
        )
      : createQuantity('eth', '0'); /*;*/

    const melonTransaction = {
      amguInEth,
      params,
      rawTransaction: {
        data: prepared.encoded,
        from: `${environment.wallet.address}`,
        gas: `${prepared.gasEstimation}`,
        gasPrice: `${environment.options.gasPrice}`,
        to: `${contractAddress}`,
        value: `${amguInEth.quantity}`,
      },
      transactionArgs: prepared.transaction.arguments,
    };

    return melonTransaction;
  };

  const send: SendFunction<Args> = async (
    contractAddress,
    prepared,
    params,
    // TODO: investigate options
    options = providedOptions,
    environment = getGlobalEnvironment(),
  ) => {
    //  const receipt = await sendTransaction(prepared, options, environment);
    const receipt = await environment.eth.sendTransaction(
      prepared.rawTransaction,
    );

    const contractInstance = getContract(contract, contractAddress);

    console.log(contractInstance.options.jsonInterface);

    const events = receipt.logs.map(log =>
      Web3EthAbi.decodeLog(
        contractInstance.options.jsonInterface,
        log.data,
        log.topics,
      ),
    );

    console.log(events);

    const postprocessed = await postProcess(
      receipt,
      params,
      contractAddress,
      environment,
    );

    return postprocessed;
  };

  const execute: EnhancedExecute<Args, Result> = async (
    contractAddress,
    params,
    environment = getGlobalEnvironment(),
  ) => {
    const prepared = await prepare(contractAddress, params, environment);
    const result = await send(
      contractAddress,
      prepared,
      params,
      providedOptions,
      environment,
    );
    return result;
  };

  execute.prepare = prepare;
  execute.send = send;

  return execute;
};

/**
 * Wraps the result of the transaction factory (EnhancedExecute) in helper
 * functions that do not require to provide contractAddress, but derive this
 * from the params with the contractAddressQuery
 *
 * @param contractAddressQuery
 * @param transaction
 */
const withContractAddressQuery: WithContractAddressQuery = <Args, Result>(
  contractAddressQuery,
  transaction,
) => {
  const prepare = async (params: Args, environment?) =>
    await transaction.prepare(
      R.path(contractAddressQuery, params).toString(),
      params,
      environment,
    );

  const send = async (
    prepared,
    params: Args,
    providedOptions,
    environment?,
  ): Promise<Result> =>
    await transaction.send(
      R.path(contractAddressQuery, params).toString(),
      prepared,
      params,
      providedOptions,
      environment,
    );

  const execute = async (params: Args, environment?) => {
    return await transaction(
      R.path(contractAddressQuery, params).toString(),
      params,
      environment,
    );
  };

  execute.prepare = prepare;
  execute.send = send;

  return execute;
};

export { transactionFactory, withContractAddressQuery };

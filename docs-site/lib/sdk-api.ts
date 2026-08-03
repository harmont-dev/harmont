import api from '../sdk-api.json';
import type { SdkApi, SdkFunction } from './sdk-api-core';

export type { SdkApi, SdkFunction, SdkParam } from './sdk-api-core';
export { renderSignature } from './sdk-api-core';

export const sdkApi = api as SdkApi;
export const sdkFunctions = sdkApi.functions;

export function findFunction(name: string): SdkFunction | null {
  return sdkFunctions.find((f) => f.name === name) ?? null;
}

import catalog from '../error-catalog.json';

export interface ErrorSpec {
  code: string;
  type: string;
  http_status: number;
  message: string;
  doc_url: string;
}

export const errorCatalog = catalog as ErrorSpec[];

export const errorByCode = new Map<string, ErrorSpec>(
  errorCatalog.map((e) => [e.code, e]),
);

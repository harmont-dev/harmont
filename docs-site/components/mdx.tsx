import defaultMdxComponents from 'fumadocs-ui/mdx';
import { Card, Cards } from 'fumadocs-ui/components/card';
import { Step, Steps } from 'fumadocs-ui/components/steps';
import { Tabs, Tab } from 'fumadocs-ui/components/tabs';
import { APIPage } from '@/components/api-page';
import { DslSignature } from '@/components/dsl-signature';
import { ErrorMeta } from '@/components/error-meta';
import { PipelineDag } from '@/components/pipeline-dag';
import { RemoteCode } from '@/components/remote-code';
import { SdkSignature } from '@/components/sdk-signature';
import { SdkTabs } from '@/components/sdk-tabs';
import { Tree } from '@/components/tree';
import type { MDXComponents } from 'mdx/types';

export function getMDXComponents(components?: MDXComponents) {
  return {
    ...defaultMdxComponents,
    APIPage,
    DslSignature,
    SdkSignature,
    ErrorMeta,
    Card,
    Cards,
    Step,
    Steps,
    Tabs,
    Tab,
    SdkTabs,
    PipelineDag,
    RemoteCode,
    Tree,
    ...components,
  } satisfies MDXComponents;
}

export const useMDXComponents = getMDXComponents;

declare global {
  type MDXProvidedComponents = ReturnType<typeof getMDXComponents>;
}

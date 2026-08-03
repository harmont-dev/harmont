import type { BaseLayoutProps } from 'fumadocs-ui/layouts/shared';

export function baseOptions(): BaseLayoutProps {
  return {
    nav: {
      title: (
        <>
          <svg
            viewBox="0 0 1024 1024"
            width={18}
            height={18}
            aria-hidden
            focusable={false}
            style={{ display: 'block' }}
          >
            <path
              fill="currentColor"
              d="M627.78,527.44c-67-69.46-98.5-101-50.74-251.25l12.51-36.07c1.27-3.46.69-5.47-4.24-5.47h-80c-4.67,0-5.82.8-7.85,5.86L327.72,729.59c-1,2.76-.45,4.85,3.73,4.85h83.1c2.56,0,3.77-.88,4.65-3.42l78.36-225.81A212.81,212.81,0,0,0,533,545.44c58.42,52.24,80.31,78.28,69.86,180.49-.72,7,.33,8.51,7.46,8.51h79.87c2.88,0,4-1.77,4.18-4.56C702,634.09,681.51,583.16,627.78,527.44Z"
            />
          </svg>
          <span>Harmont docs</span>
        </>
      ),
      url: '/',
    },
    githubUrl: 'https://github.com/harmont-dev',
    searchToggle: { enabled: true },
  };
}

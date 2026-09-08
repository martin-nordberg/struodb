import { defineConfig } from 'vitepress'

// https://vitepress.dev/reference/site-config
export default defineConfig({
  title: "StruoDB Documentation",
  description: "Documentation for StruoDB architecture, implementation, and usage.",
  head: [
    ['link', { rel: 'icon', type: 'image/svg+xml', href: '/favicon.svg' }],
    ['link', { rel: 'icon', href: '/favicon.ico', sizes: 'any' }],
  ],
  themeConfig: {
    // https://vitepress.dev/reference/default-theme-config
    nav: [
      { text: 'Home', link: '/' },
      { text: 'Specifications', link: '/specifications/struoql/overview' },
      { text: 'Designs', link: '/designs/ideas/overview' },
    ],

    sidebar: {
      '/specifications/': [
        {
          text: 'StruoQL',
          collapsed: true,
          items: [
            {text: '1. Overview', link: '/specifications/struoql/overview'},
            {text: '2. Lexical Spec', link: '/specifications/struoql/lexical-spec'},
            {text: '3. Schema Definition', link: '/specifications/struoql/ddl-spec'},
            {text: '4. Event Creation', link: '/specifications/struoql/dml-spec'},
            {text: 'A. Design Decisions', link: '/specifications/struoql/design-decisions'},
          ]
        },
        {
          text: 'Internals',
          collapsed: true,
          items: [
            {text: 'Overview', link: '/specifications/internals/overview'},
            {text: 'Hybrid Logical Clock', link: '/specifications/internals/hlc-spec'},
            {text: 'References', link: '/specifications/internals/references'},
          ]
        },
      ],
      '/designs': [
        {
          text: 'Ideas',
          collapsed: true,
          items: [
            {text: 'Overview', link: '/designs/ideas/overview'},
          ]
        },
      ],
    },

    outline: {
      level: [2, 2]
    },

    socialLinks: [
      { icon: 'github', link: 'https://github.com/martin-nordberg/struodb' }
    ]
  }
})

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
          text: 'Architecture',
          collapsed: true,
          items: [
            {text: '1. Overview', link: '/specifications/architecture/overview'},
            {text: '2. Event Collectors', link: '/specifications/architecture/event-collectors'},
            {text: '3. Event Aggregators', link: '/specifications/architecture/event-aggregators'},
            {text: '4. Event Propagation', link: '/specifications/architecture/event-propagation'},
            {text: '5. Event Projectors', link: '/specifications/architecture/event-projectors'},
          ]
        },
        {
          text: 'StruoQL',
          collapsed: true,
          items: [
            {text: '1. Overview', link: '/specifications/struoql/overview'},
            {text: '2. Lexical Spec', link: '/specifications/struoql/lexical-spec'},
            {text: '3. Expressions', link: '/specifications/struoql/expressions'},
            {text: '4. Schema Definition', link: '/specifications/struoql/ddl-spec'},
            {text: '5. Event Creation', link: '/specifications/struoql/dml-spec'},
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
      level: [2, 3]
    },

    socialLinks: [
      { icon: 'github', link: 'https://github.com/martin-nordberg/struodb' }
    ]
  }
})

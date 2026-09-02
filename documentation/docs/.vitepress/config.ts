import { defineConfig } from 'vitepress'

// https://vitepress.dev/reference/site-config
export default defineConfig({
  title: "StruoDB Documentation",
  description: "Documentation for StruoDB architecture, implementation, and usage.",
  themeConfig: {
    // https://vitepress.dev/reference/default-theme-config
    nav: [
      { text: 'Home', link: '/' },
      { text: 'StruoQL', link: '/struoql/overview' }
    ],

    sidebar: [
      {
        text: 'StruoQL',
        collapsed: true,
        items: [
          { text: 'Overview', link: '/struoql/overview' },
          { text: 'Lexical Spec', link: '/struoql/lexical-spec' },
          { text: 'Schema Definition', link: '/struoql/ddl-spec' },
          { text: 'Event Creation', link: '/struoql/dml-spec' },
          { text: 'Design Decisions', link: '/struoql/design-decisions' },
        ]
      },
      {
        text: 'Internals',
        collapsed: true,
        items: [
          { text: 'Overview', link: '/internals/overview' },
          { text: 'Hybrid Logical Clock', link: '/internals/hlc-spec' },
          { text: 'References', link: '/internals/references' },
        ]
      }
    ],

    socialLinks: [
      { icon: 'github', link: 'https://github.com/martin-nordberg/struodb' }
    ]
  }
})

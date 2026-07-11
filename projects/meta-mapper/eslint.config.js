const { defineConfig } = require('eslint/config');
const eslintJs = require('@eslint/js');
const jestPlugin = require('eslint-plugin-jest');
const auraConfig = require('@salesforce/eslint-plugin-aura');
const lwcConfig = require('@salesforce/eslint-config-lwc/recommended');
const globals = require('globals');

module.exports = defineConfig([
    // Aura configuration
    {
        files: ['**/aura/**/*.js'],
        extends: [
            ...auraConfig.configs.recommended,
            ...auraConfig.configs.locker
        ]
    },

    // LWC configuration
    // @lwc/lwc/no-async-operation is turned off (rather than inline-disabled per call site,
    // which @lwc/lwc-platform/no-inline-disable forbids) because setTimeout/clearTimeout is the
    // standard, intentional pattern used throughout these components for debounce timers, deferred
    // focus management, and polling loops - each documented at its call site.
    // `echarts` is declared as a global because it is loaded at runtime from the ECharts static
    // resource (loadScript), not imported as a module - ESLint cannot statically resolve it.
    {
        files: ['**/lwc/**/*.js'],
        extends: [lwcConfig],
        rules: {
            '@lwc/lwc/no-async-operation': 'off'
        },
        languageOptions: {
            globals: {
                echarts: 'readonly'
            }
        }
    },

    // LWC configuration with override for LWC test files
    {
        files: ['**/lwc/**/*.test.js'],
        extends: [lwcConfig],
        rules: {
            '@lwc/lwc/no-unexpected-wire-adapter-usages': 'off'
        },
        languageOptions: {
            globals: {
                ...globals.node
            }
        }
    },

    // Jest mocks configuration
    {
        files: ['**/jest-mocks/**/*.js'],
        languageOptions: {
            sourceType: 'module',
            ecmaVersion: 'latest',
            globals: {
                ...globals.node,
                ...globals.es2021,
                ...jestPlugin.environments.globals.globals
            }
        },
        plugins: {
            eslintJs
        },
        extends: ['eslintJs/recommended']
    }
]);
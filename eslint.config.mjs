import js from '@eslint/js';
import {defineConfig} from 'eslint/config';

const rules = {
    eqeqeq: ['error', 'always'],
    'no-var': 'error',
    'object-curly-spacing': ['error', 'never'],
    'prefer-const': 'error',
    quotes: ['error', 'single', {avoidEscape: true}],
    semi: ['error', 'always'],
};

export default defineConfig([
    js.configs.recommended,
    {
        files: ['extension/**/*.js'],
        languageOptions: {
            ecmaVersion: 'latest',
            sourceType: 'module',
            globals: {
                logError: 'readonly',
            },
        },
        rules,
    },
    {
        // GNOME Shell 42 loads extension.js as a legacy script (imports.*).
        files: ['extension-legacy/**/*.js'],
        languageOptions: {
            ecmaVersion: 2021,
            sourceType: 'script',
            globals: {
                imports: 'readonly',
                logError: 'readonly',
            },
        },
        rules,
    },
]);

import js from '@eslint/js';
import {defineConfig} from 'eslint/config';

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
        rules: {
            eqeqeq: ['error', 'always'],
            'no-var': 'error',
            'object-curly-spacing': ['error', 'never'],
            'prefer-const': 'error',
            quotes: ['error', 'single', {avoidEscape: true}],
            semi: ['error', 'always'],
        },
    },
]);

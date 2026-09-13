const { loadConfig } = require('../../src/config');

describe('loadConfig', () => {
  test('applies defaults', () => {
    const cfg = loadConfig({});
    expect(cfg).toEqual({
      port: 3000,
      appEnv: 'dev',
      databaseUrl: undefined,
      version: 'dev',
    });
  });

  test('reads values from env and parses port as a number', () => {
    const cfg = loadConfig({
      PORT: '4001',
      APP_ENV: 'staging',
      APP_VERSION: 'abc123',
      DATABASE_URL: 'postgres://u:p@h:5432/d',
    });
    expect(cfg.port).toBe(4001);
    expect(cfg.appEnv).toBe('staging');
    expect(cfg.version).toBe('abc123');
    expect(cfg.databaseUrl).toBe('postgres://u:p@h:5432/d');
  });

  test('throws when DATABASE_URL is required but missing', () => {
    expect(() => loadConfig({}, { requireDb: true })).toThrow('DATABASE_URL is required');
  });

  test('rejects a non-numeric PORT', () => {
    expect(() => loadConfig({ PORT: 'abc' })).toThrow('PORT must be a number');
  });
});

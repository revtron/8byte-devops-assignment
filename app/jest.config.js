module.exports = {
  testEnvironment: 'node',
  testMatch: ['**/test/**/*.test.js'],
  reporters: [
    'default',
    ['jest-junit', { outputDirectory: 'reports', outputName: 'junit.xml' }],
  ],
  collectCoverageFrom: ['src/**/*.js'],
};

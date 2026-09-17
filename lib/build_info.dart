const appBuildNumber = String.fromEnvironment(
  'APP_BUILD_NUMBER',
  defaultValue: 'local',
);

String get appBuildLabel => 'Build $appBuildNumber';

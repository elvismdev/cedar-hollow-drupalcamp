// Copied from uclahs/surface (GPL-2.0-or-later), .storybook/drupal/drupal.js at 76e5dc6.
import './drupalSettings';

// Simple Drupal.behaviors usage for Storybook

window.Drupal = { behaviors: {} };

((Drupal, drupalSettings) => {
  Drupal.throwError = (error) => {
    setTimeout(() => {
      throw error;
    }, 0);
  };

  Drupal.attachBehaviors = (context, settings) => {
    context = context || document;
    settings = settings || drupalSettings;
    const behaviors = Drupal.behaviors;

    Object.keys(behaviors).forEach((i) => {
      if (typeof behaviors[i].attach === 'function') {
        try {
          behaviors[i].attach(context, settings);
        } catch (e) {
          Drupal.throwError(e);
        }
      }
    });
  };
})(Drupal, window.drupalSettings);

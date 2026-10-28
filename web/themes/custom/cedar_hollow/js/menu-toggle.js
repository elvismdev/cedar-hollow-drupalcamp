/**
 * @file
 * Shows and hides the main navigation on small screens.
 */

((Drupal, once) => {
  Drupal.behaviors.cedarHollowMenuToggle = {
    attach(context) {
      once('cedar-hollow-menu-toggle', '[data-menu-toggle]', context).forEach((button) => {
        const menu = document.getElementById(button.getAttribute('aria-controls'));
        if (!menu) {
          return;
        }
        button.addEventListener('click', () => {
          const open = button.getAttribute('aria-expanded') === 'true';
          button.setAttribute('aria-expanded', String(!open));
          menu.classList.toggle('is-open', !open);
        });
      });
    },
  };
})(Drupal, once);

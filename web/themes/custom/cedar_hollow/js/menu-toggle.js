/**
 * @file
 * Collapses the main navigation behind a toggle button on small screens.
 *
 * CSS collapses the list and shows the button whenever scripting is on, so
 * the page is laid out once; this behavior only opens and closes the list.
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

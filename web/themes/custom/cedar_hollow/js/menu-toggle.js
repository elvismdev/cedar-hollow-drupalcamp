/**
 * @file
 * Collapses the main navigation behind a toggle button on small screens.
 *
 * Progressive enhancement: the markup shows every link and hides the button.
 * This behavior reveals the button and marks the menu collapsible, and only
 * then does CSS collapse the list.
 */

((Drupal, once) => {
  Drupal.behaviors.cedarHollowMenuToggle = {
    attach(context) {
      once('cedar-hollow-menu-toggle', '[data-menu-toggle]', context).forEach((button) => {
        const menu = document.getElementById(button.getAttribute('aria-controls'));
        if (!menu) {
          return;
        }
        button.closest('.main-menu')?.classList.add('main-menu--collapsible');
        button.hidden = false;
        button.addEventListener('click', () => {
          const open = button.getAttribute('aria-expanded') === 'true';
          button.setAttribute('aria-expanded', String(!open));
          menu.classList.toggle('is-open', !open);
        });
      });
    },
  };
})(Drupal, once);

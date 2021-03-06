var main = Elm.fullscreen(Elm.Main, { bodyFocused : true });

function updatePort() {
  main.ports.bodyFocused.send(document.activeElement === document.body);
}

window.addEventListener ? window.addEventListener('focus', updatePort, true) : window.attachEvent('onfocusout', updatePort);
window.addEventListener ? window.addEventListener('blur', updatePort, true) : window.attachEvent('onblur', updatePort);

setTimeout(
  function(){
    var elt = document.getElementById('help-card-title');
    if (elt.parentElement.childElementCount === 2) {
      elt.click();
    }
  }, 10000)

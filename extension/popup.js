const keyInput = document.querySelector('#cartesiaKey');
const saveButton = document.querySelector('#save');
const statusText = document.querySelector('#status');

chrome.storage.sync.get(['cartesiaKey'], (data) => {
  keyInput.value = data.cartesiaKey ?? '';
});

saveButton.addEventListener('click', () => {
  const cartesiaKey = keyInput.value.trim();
  chrome.storage.sync.set({ cartesiaKey }, () => {
    statusText.textContent = 'Saved';
    setTimeout(() => {
      statusText.textContent = '';
    }, 1600);
  });
});

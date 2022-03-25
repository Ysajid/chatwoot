import { debounce } from '../TimeHelpers';
// Tell Jest to mock all timeout functions
jest.useFakeTimers('modern');

describe('debounce', () => {
  let func;
  let debouncedFunc;

  beforeEach(() => {
    func = jest.fn();
    debouncedFunc = debounce(func, 1000);
  });

  test('execute just once with immediate false', () => {
    for (let i = 0; i < 100; i += 1) {
      debouncedFunc();
    }

    // Fast-forward time
    jest.runAllTimers();

    expect(func).toBeCalledTimes(1);
  });

  test('execute just once with immediate true', () => {
    for (let i = 0; i < 100; i += 1) {
      debouncedFunc();
    }

    // Fast-forward time
    jest.runAllTimers();

    expect(func).toBeCalledTimes(1);
  });
});
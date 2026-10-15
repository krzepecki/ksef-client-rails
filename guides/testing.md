# Testing your app

Your tests shouldn't call KSeF. `ksef/testing` adds WebMock stubs that answer the way KSeF does, so
your sign-in and invoice-sending code runs offline:

```ruby
require "webmock/rspec"
require "ksef/testing"

include Ksef::Testing
stub_ksef_authentication                                    # token or XAdES sign-in and refresh
stub_ksef_online_session(ksef_number: Ksef::Testing.ksef_number)   # every invoice accepted, with a UPO
```

- WebMock must be enabled — `require "webmock/rspec"`, `"webmock/minitest"` or `WebMock.enable!`.
  Otherwise the stubs are bypassed and the requests reach KSeF.
- Each stub takes `config:` for another environment.
- For other endpoints, stub them with WebMock directly.
- Tests that travel in time (`travel_to`, Timecop) work in any order: the stubbed Ministry certificate
  is valid from 2000 to 2099.

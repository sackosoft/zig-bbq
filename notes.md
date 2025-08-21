## Implementation notes and reminders for investigation/experimentation.

- 4.5 - "Finally, we have optimized BBQ for SPSC scenarios as follows:
        (1) phead and chead are no longer shared variables and
        can be accessed with non-atomic loads/stores. (2) allocated
        and committed(resp. reservedandconsumers)are merged
        into one variable and updated with STORE"
    - This leads me to believe that there may be a lot of value to further
      specialize BBQ with comptime information. With a comptime known number
      of producers and consumers (and runtime assertions in Debug and ReleaseSafe
      builds) we can apply futher optimizations.

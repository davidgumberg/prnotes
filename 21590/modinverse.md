# Modular inverses      

We write the modular inverse of $x$ as $x^-1$ where $(x * x^-1) \mod z = 1$ or
in modular congruence notation $x * x^-1 \equiv 1 (mod z)$.

<details>

<summary>

Only numbers coprime to $z$ have a modular inverse. Why?

</summary>

Let's take the example of the modular inverse of $4 \mod 6$, we are looking for
some multiple of four, $K * 4$, where $(K * 4) \mod 6 = 1$ or in other words a
multiple of four that is one greater than some multiple of six, let's look for a
modular inverse of $4$ naively by checking different values of $K$:

| K | multiples of four (K * 4) | nearest multiple of six <= K * 4 | (K * 4) mod 6  |
|---|---------------------------|----------------------------------|---------------:|
| 0 | 0                         | 0                                |              0 |
| 1 | 4                         | 0                                |              4 |
| 2 | 8                         | 6                                |              2 |
| 3 | 12                        | 12                               |              0 |
| 4 | 16                        | 12                               |              4 |
| 5 | 20                        | 18                               |              2 |

You can see that the numbers will continue to loop, in fact because of the
property that $(x + y) \mod z = ((x \mod z) + (y \mod z)) \mod z$ we can be
totally sure this loop will continue forever. Taking the next item in the sequence
from the table $K = 6$, $24 mod 6 = ((20 mod 6) + (4 mod 6)) mod 6 = (2 + 4) mod
6 = 0$ and so on.

That's enough to show that not all integers which are not coprime to a 'divisor'
($z$ above) have a modular inverse. I want to get a little closer and show that
all integers 'dividends' ($x above) which are not coprime to a divisor $z$ have
no modular inverse.

Using the same example as above, one might say something like:

"OK, I can see that $K*4 mod 6$ goes in a loop that never visits $1$, and I can
also see that entering a loop is inevitable because there are only $6$ possible
integers that can result from taking some number $\mod 6$ (0-5), and once I've
tried at least $z$ many versions of $K$ for any version of this problem I'm
guaranteed to have to hit some remainder I've seen before before, and will loop
because of the addition rule described above.

But, how can I be sure that there isn't *some* $x$ and $z$ out there which are
not coprime, where $x$ has a multiple that is 1 greater than some multiple of
$z$?"

OK, first, before answering I want to try two coprimes, let's look for the
inverse of $K * x \mod z$ where $x = 4$ and $z = 9$:

| K     | multiples of 4 (K * 4) | nearest multiple of 9 <= K * 4 | (K * 4) mod 9  |
|-------|------------------------|--------------------------------|---------------:|
| 0     | 0                      | 0                              |              0 |
| 1     | 4                      | 0                              |              4 |
| 2     | 8                      | 0                              |              8 |
| 3     | 12                     | 9                              |              3 |
| 4     | 16                     | 9                              |              7 |
| 5     | 20                     | 18                             |              2 |
| 6     | 24                     | 18                             |              6 |
| **7** | **28**                 | **27**                         |          **1** |
| 8     | 32                     | 27                             |              5 |
| 9     | 36                     | 36                             |              0 |
| 10    | 40                     | 36                             |              4 |



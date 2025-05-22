This account is simplified and deliberately avoids complications like `k`, but
I think is sufficient to understand the issue here.

ECDSA signatures suffer from a form of malleability that is an inherent property
of elliptic curve addition.

If you take two points at random on an elliptic curve, $a$ and $b$ and draw a
line through them, that line will usually intersect the curve at a third point,
$c$. There are two exceptions where this is not the case, one is when you have a
line that is tangent to the curve, and the other is when the line is vertical,
or $a.x == b.x$ and $a.y = -b.y$, but I'll return to this.

When you "add" two points on an elliptic curve, you draw a line through the two
points and find the third point that intersects the curve, $c$, and then you
reflect across the x-axis, aka draw a vertical line, aka negate this point $C$
and your sum is $-C$ and that is the sum.

### Negation / Identity property

The identity member of the set of natural numbers is 0, since any member $x$:

$$ x + 0 = x $$

And this constrains, or includes the definition of negativity since it requires
that:

$$ x + (-x) = 0 $$

On the elliptic curve, this refers to the "vertical line" situation, the third
point of such a sum is said to be the point at infinity, and this is the
identity member. Thinking back on the earlier account, that the sum of two
points, $A$ and $B$ is the reflection of the third point $C$ over the x-axis,
$-C$, we find something strange, but coherent with this identity property, the
sum of any point $A$ and "0", or the identity point, is the point $-A$

![CC BY-SA 3.0 - Author: SuperManu (https://commons.wikimedia.org/wiki/File:ECClines.svg)](ECClines.svg "ECC Lines, CC BY-SA 3.0")


